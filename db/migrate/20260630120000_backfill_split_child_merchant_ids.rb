class BackfillSplitChildMerchantIds < ActiveRecord::Migration[7.2]
  def up
    # Copy parent transaction's merchant_id to child split transactions where null
    execute <<~SQL
      UPDATE transactions AS child_t
      SET merchant_id = parent_t.merchant_id
      FROM entries AS child_e
      JOIN entries AS parent_e ON parent_e.id = child_e.parent_entry_id
      JOIN transactions AS parent_t
        ON parent_t.id = parent_e.entryable_id
       AND parent_e.entryable_type = 'Transaction'
      WHERE child_t.id = child_e.entryable_id
        AND child_e.entryable_type = 'Transaction'
        AND child_e.parent_entry_id IS NOT NULL
        AND child_t.merchant_id IS NULL
        AND parent_t.merchant_id IS NOT NULL
    SQL
  end

  def down
    # Not reversible — we don't know which nulls were intentional
  end
end
