require "test_helper"

class Family::AutoCategoryRuleCreatorTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  AutoCategorization = Provider::LlmConcept::AutoCategorization

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries_category = @family.categories.create!(name: "Groceries")
    @salary_category = @family.categories.create!(name: "Salary", classification: "income")
    @llm_provider = mock("llm_provider")
    Provider::Registry.stubs(:preferred_llm_provider).returns(@llm_provider)
  end

  test "creates category rules for uncategorized transaction groups using the configured provider" do
    create_transaction(account: @account, name: "Netflix", amount: 15, date: 2.days.ago.to_date)
    create_transaction(account: @account, name: "Netflix", amount: 20, date: 1.day.ago.to_date)
    create_transaction(account: @account, name: "Payroll", amount: -2000, date: Date.current)

    groups = Transaction::Grouper.strategy.call(@family.entries, limit: @family.entries.uncategorized_transactions.count)
    categorizations = groups.map do |group|
      category_name = group.grouping_key == "Payroll" ? @salary_category.name : @groceries_category.name
      AutoCategorization.new(transaction_id: group.entries.first.transaction.id, category_name: category_name)
    end

    @llm_provider.expects(:auto_categorize).with do |transactions:, user_categories:, family:|
      assert_equal @family, family
      assert_equal groups.map { |group| group.entries.first.transaction.id }, transactions.map { |transaction| transaction[:id] }
      assert_equal @family.categories.order(:id).pluck(:name).sort, user_categories.map { |category| category[:name] }.sort
      true
    end.once.returns(provider_success_response(categorizations))

    result = nil

    assert_difference "@family.rules.count", 2 do
      result = Family::AutoCategoryRuleCreator.new(@family, entries: @family.entries).create_rules
    end

    assert_equal 2, result[:created_count]
    assert_equal 0, result[:skipped_count]
    assert_nil result[:error]

    netflix_rule = @family.rules.find_by!(name: "Netflix")
    assert netflix_rule.conditions.any? { |condition| condition.condition_type == "transaction_name" && condition.value == "Netflix" }
    assert netflix_rule.conditions.any? { |condition| condition.condition_type == "transaction_type" && condition.value == "expense" }
    assert_equal @groceries_category.id, netflix_rule.actions.first.value

    payroll_rule = @family.rules.find_by!(name: "Payroll")
    assert payroll_rule.conditions.any? { |condition| condition.condition_type == "transaction_type" && condition.value == "income" }
    assert_equal @salary_category.id, payroll_rule.actions.first.value
  end

  test "skips groups when a matching rule already exists" do
    create_transaction(account: @account, name: "Netflix", amount: 15, date: Date.current)
    Rule.create_from_grouping(@family, "Netflix", @groceries_category, transaction_type: "expense")

    groups = Transaction::Grouper.strategy.call(@family.entries, limit: @family.entries.uncategorized_transactions.count)
    categorizations = groups.map do |group|
      AutoCategorization.new(transaction_id: group.entries.first.transaction.id, category_name: @groceries_category.name)
    end

    @llm_provider.expects(:auto_categorize).once.returns(provider_success_response(categorizations))

    assert_no_difference "@family.rules.count" do
      result = Family::AutoCategoryRuleCreator.new(@family, entries: @family.entries).create_rules
      assert_equal 0, result[:created_count]
      assert_equal 1, result[:skipped_count]
    end
  end

  test "returns provider failures without creating rules" do
    create_transaction(account: @account, name: "Netflix", amount: 15, date: Date.current)

    @llm_provider.expects(:auto_categorize).once.returns(
      provider_error_response(StandardError.new("Provider unavailable"))
    )

    assert_no_difference "@family.rules.count" do
      result = Family::AutoCategoryRuleCreator.new(@family, entries: @family.entries).create_rules
      assert_equal "Provider unavailable", result[:error]
    end
  end
end
