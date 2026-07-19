# Changelog

## 0.4.0 (2026-07-19)

### Fixes

- The single-column `[fk_id]` index on multitenant resources is now generated with
  `include_base_filter?: false`. Previously, a resource `base_filter` (e.g.
  `deleted_at IS NULL`) was baked into the index as a `WHERE` clause, making it
  partial — but FK constraint checks (e.g. deletes on the referenced table) must see
  **all** rows, so such an index could not serve them.
- That index now gets a stable name, `{table}_{fk_id}_fkey_index`, instead of the
  default derived name.

### Dependencies

- Requires `ash_postgres` with `include_base_filter?` support for custom indexes
  (ash-project/ash_postgres#796, not yet in a hex release — currently GitHub main).

### Upgrading from 0.3.x

On multitenant resources with a `base_filter`, running `mix ash.codegen` will
regenerate the single-column FK indexes without the base filter (and with the new
name). This is intentional — the filtered indexes could not back FK constraint
checks.

## 0.3.0 (2026-07-16)

### Breaking / behavior changes

- Relationships with a manual `reference` are no longer skipped. Previously, any
  relationship mentioned in the `references` block was ignored entirely — a
  `reference :foo, on_delete: :delete` without `index?: true` silently ended up with
  **no index at all**. Now the plugin checks `index?` and, when missing, adds the index
  via `custom_indexes` instead (a relationship can only have one `reference` entity).
  (#1, thanks @DGollings)
- Multitenant resources (attribute strategy) now get **two** indexes per `belongs_to`:
  the composite `[tenant_attr, fk_id]` index as before, plus a single-column `[fk_id]`
  index with `all_tenants?: true`. FK constraint checks (e.g. deletes on the referenced
  table) are not tenant-scoped, so the composite index cannot serve them. (#1)

### Fixes

- Conflict detection recognizes covering composite custom indexes via the leftmost
  prefix rule (e.g. `index [:fk_id, :created_at]` covers `:fk_id`), instead of
  requiring an exact field match.
- Partial custom indexes (with a `where` clause) no longer suppress index creation
  unless their condition is implied by FK lookups (`"fk_id IS NOT NULL"`). Previously
  an index like `index [:fk_id], where: "deleted_at IS NULL"` was wrongly treated as
  covering the FK.

### Upgrading from 0.2.x

Running `mix ash.codegen` after upgrading will generate new index migrations:

- for every relationship that had a manual `reference` without `index?: true`
- a single-column index per `belongs_to` on multitenant resources

This is intentional — these are indexes that were previously missing. Review the
generated migration and use `except` for any relationship you deliberately do not
want indexed.

## 0.2.0

- Generate `reference ..., index?: true` entries instead of custom indexes.
- Skip relationships already defined in the `references` block.

## 0.1.0

- Initial release: automatically add indexes for all `belongs_to` relationships.
