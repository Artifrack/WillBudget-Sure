class AddAccountIdsToRejectedTransfers < ActiveRecord::Migration[8.1]
  def change
    add_column :rejected_transfers, :inflow_account_id, :uuid
    add_column :rejected_transfers, :outflow_account_id, :uuid

    # Backfill existing rows from their transactions' entries
    execute <<~SQL
      UPDATE rejected_transfers
      SET
        inflow_account_id  = (SELECT e.account_id FROM entries e WHERE e.entryable_id = rejected_transfers.inflow_transaction_id  AND e.entryable_type = 'Transaction' LIMIT 1),
        outflow_account_id = (SELECT e.account_id FROM entries e WHERE e.entryable_id = rejected_transfers.outflow_transaction_id AND e.entryable_type = 'Transaction' LIMIT 1)
    SQL

    add_index :rejected_transfers, [ :inflow_account_id, :outflow_account_id ],
              name: "idx_rejected_transfers_account_pair"
  end
end
