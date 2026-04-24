# Content Uploads in Katello

How file uploads (RPMs, debs, etc.) flow from the API through to Pulp 3.

## The 3-Step Upload Flow

Uploading content into a repository is a multi-step process spanning two controllers:

1. **Create upload** — `POST /katello/api/v2/repositories/:repo_id/content_uploads`
   - Controller: `content_uploads_controller.rb`
   - Calls `Pulp3::Content.create_upload(size)` → `POST /pulp/api/v3/uploads/`
   - Pulp allocates a staging slot; returns an `upload_id` (UUID)
   - The Pulp upload object has **no association with any repository** — just a size

2. **Upload chunks** — `PUT /katello/api/v2/repositories/:repo_id/content_uploads/:id`
   - Controller: `content_uploads_controller.rb`
   - Calls `Pulp3::Content.upload_chunk(href, offset, content, size)`
   - Pushes file bytes to the Pulp upload slot via `PUT` with `Content-Range` headers
   - Can be called multiple times for large files

3. **Import uploads** — `PUT /katello/api/v2/repositories/:repo_id/import_uploads`
   - Controller: `repositories_controller.rb`
   - This is the step that actually **commits content into the repository**
   - Uses `find_authorized_katello_resource` with `.editable` scope — properly authorized

## Pulp Upload Objects

A Pulp upload (`/pulp/api/v3/uploads/<uuid>/`) is:
- A temporary staging area for chunked file transfer
- Completely standalone — not tied to any repo, content type, or artifact
- Created with just a `size` parameter
- Consumed when committed (step 3), but if never committed, it **persists indefinitely**

### Cleanup

- **Katello's `delete_upload` is a no-op** for Pulp 3 — see `Pulp3::Content.delete_upload`:
  ```ruby
  def delete_upload(upload_href)
    #Commit deletes upload request for pulp3. Not needed other than to implement abstract method.
  end
  ```
- **Pulp orphan cleanup does NOT remove uncommitted uploads.** Orphan cleanup targets
  orphaned Content units and Artifacts, not uploads. Uploads are a separate resource type.
- Uncommitted uploads sit in Pulp storage as dead weight forever unless explicitly
  deleted via `DELETE /pulp/api/v3/uploads/<uuid>/`.

## Related: Permission Mapping

Content upload actions are mapped to `edit_products` in `lib/katello/permission_creator.rb`:

```ruby
@plugin.permission :edit_products,
  { 'katello/api/v2/content_uploads' => [:create, :update, :destroy] },
  :resource_type => 'Katello::Product',
  :finder_scope => :editable
```
