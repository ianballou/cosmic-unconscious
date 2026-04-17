---
name: ruby-rails
description: Ruby on Rails conventions and patterns for Foreman ecosystem projects
---

# Ruby / Rails Patterns

## Testing
- Run tests from the Foreman root: `cd /home/vagrant/foreman`
- Katello tests: `bundle exec rake test:katello:test TESTOPTS="-v"`
- Single test file: `bundle exec ruby -Itest /path/to/test.rb`
- Single test method: `bundle exec ruby -Itest /path/to/test.rb -n test_method_name`
- RuboCop: `cd /home/vagrant/katello && bundle exec rubocop --parallel`

## Rails Console
- `cd /home/vagrant/foreman && bundle exec rails console`

## Common Patterns
- Factories use FactoryBot: `FactoryBot.create(:katello_repository)`
- Fixtures live alongside test files or in test/fixtures/
- Concerns are used heavily for shared model behavior
- Scoped search is used for index/search endpoints

## Gotchas
(Add entries here as discovered)
