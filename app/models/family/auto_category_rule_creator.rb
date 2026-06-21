class Family::AutoCategoryRuleCreator
  def initialize(family, entries:)
    @family = family
    @entries = entries
  end

  def create_rules
    return failure("No LLM provider configured") unless llm_provider

    grouped_entries = uncategorized_groups
    return success if grouped_entries.empty?

    result = llm_provider.auto_categorize(
      transactions: transactions_input(grouped_entries),
      user_categories: user_categories_input,
      family: family
    )

    return failure(result.error&.message || "Failed to auto-categorize transaction groups") unless result.success?

    categories_by_name = family.categories.index_by(&:name)
    categorizations_by_transaction_id = result.data.index_by(&:transaction_id)
    created_count = 0
    skipped_count = 0

    grouped_entries.each do |group|
      categorization = categorizations_by_transaction_id[group.entries.first.transaction.id]
      category = categories_by_name[categorization&.category_name]

      if category.present? && Rule.create_from_grouping(family, group.grouping_key, category, transaction_type: group.transaction_type)
        created_count += 1
      else
        skipped_count += 1
      end
    end

    success(created_count:, skipped_count:)
  end

  private
    attr_reader :entries, :family

    def llm_provider
      Provider::Registry.preferred_llm_provider
    end

    def uncategorized_groups
      uncategorized_count = entries.uncategorized_transactions.count
      Transaction::Grouper.strategy.call(entries, limit: uncategorized_count)
    end

    def user_categories_input
      family.categories.map do |category|
        {
          id: category.id,
          name: category.name,
          is_subcategory: category.subcategory?,
          parent_id: category.parent_id
        }
      end
    end

    def transactions_input(grouped_entries)
      grouped_entries.map do |group|
        representative_transaction = group.entries.first.transaction

        {
          id: representative_transaction.id,
          amount: representative_transaction.entry.amount.abs,
          classification: representative_transaction.entry.classification,
          description: [
            representative_transaction.entry.name,
            representative_transaction.entry.notes
          ].compact.reject(&:empty?).join(" "),
          merchant: representative_transaction.merchant&.name
        }
      end
    end

    def success(created_count: 0, skipped_count: 0)
      { created_count:, skipped_count:, error: nil }
    end

    def failure(error)
      { created_count: 0, skipped_count: 0, error: error }
    end
end
