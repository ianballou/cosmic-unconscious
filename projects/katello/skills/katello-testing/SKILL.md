---
name: katello-testing
description: Katello test patterns, factories, and conventions
---

# Katello Testing

## Running Tests
- All: cd /home/vagrant/foreman && bundle exec rake test:katello:test TESTOPTS="-v"
- Single file: cd /home/vagrant/foreman && bundle exec ruby -Itest /home/vagrant/katello/test/path.rb
- Single method: add -n test_method_name
- React: cd /home/vagrant/katello && npx jest webpack/path/to/test

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
