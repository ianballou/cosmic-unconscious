---
name: katello-testing
description: Katello test patterns, factories, and conventions
---

# Katello Testing

## Running Tests
All rake/rails commands run from the sibling foreman/ directory.
- All: cd ../foreman && bundle exec rake test:katello:test TESTOPTS="-v"
- Single file: cd ../foreman && bundle exec ruby -Itest ../katello/test/path.rb
- Single method: add -n test_method_name
- React: npx jest webpack/path/to/test

## Test Organization
- Model tests: test/models/katello/
- Controller tests: test/controllers/katello/api/v2/
- Action tests: test/actions/katello/
- Factories: test/factories/
- Fixtures: test/fixtures/

## Patterns
- Uses Minitest, not RSpec (for most tests)
- Factories use FactoryBot: FactoryBot.create(:katello_repository)
- Controller tests inherit from ActionController::TestCase
- Action tests stub Pulp interactions

## Gotchas
(Add entries as discovered)
