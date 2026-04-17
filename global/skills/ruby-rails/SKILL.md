---
name: ruby-rails
description: Ruby on Rails conventions and patterns for Foreman ecosystem projects
---

# Ruby / Rails Patterns

## Testing
All rake/rails commands run from the foreman directory.
- Katello tests: `bundle exec rake test:katello:test TESTOPTS="-v"`
- Single test file: `bundle exec ruby -Itest /path/to/test.rb`
- Single test method: `bundle exec ruby -Itest /path/to/test.rb -n test_method_name`
- RuboCop (from katello dir): `bundle exec rubocop --parallel`

## Rails Console
- From the foreman directory: `bundle exec rails console`

## Common Patterns
- Factories use FactoryBot: `FactoryBot.create(:katello_repository)`
- Fixtures live alongside test files or in test/fixtures/
- Concerns are used heavily for shared model behavior
- Scoped search is used for index/search endpoints

## Gotchas
(Add entries here as discovered)
