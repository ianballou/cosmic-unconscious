---
name: replace-snapshot-tests
description: Replace Enzyme snapshot tests with React Testing Library (RTL) behavioral tests in Foreman plugin projects. Use when converting snapshot tests for React 18 migration.
user-invocable: true
---

# Replace Enzyme Snapshot Tests with RTL

Guide for converting Enzyme-based snapshot tests (`testComponentSnapshotsWithFixtures`, `testActionSnapshotWithFixtures`, `testReducerSnapshotWithFixtures`, `testSelectorsSnapshotWithFixtures`, `IntegrationTestHelper`) to React Testing Library (RTL) behavioral tests.

## Context

Enzyme does not support React 18. All Enzyme-based snapshot tests must be replaced as part of the React 18 upgrade (SAT-16054). The `@theforeman/test` package is deprecated and throws on execution -- `tfm-test --plugin` no longer works.

## Running Tests

**Always run JS tests from the Foreman directory using Foreman's Jest config:**

```bash
cd /home/vagrant/foreman && npx jest --no-coverage \
  --config webpack/jest.config.js \
  --roots /home/vagrant/foreman_rh_cloud/webpack \
  --testPathPattern="ComponentName"
```

Foreman's Jest config provides:
- SCSS/CSS mocking via `identity-obj-proxy` (without it, SCSS imports cause `SyntaxError: Unexpected token '.'`)
- Module aliases (`foremanReact`, `@theforeman/test`)
- Test setup and transform configuration

**After running tests, you'll be in the Foreman directory.** Switch back to the plugin directory to see branch changes: `cd /home/vagrant/foreman_rh_cloud`

## Step 1: Assess Before Converting

**Do NOT blindly convert all snapshot tests.** For each test file, assess whether the underlying code has logic worth testing:

### DELETE these (no conversion needed):
- **Trivial selectors** -- just `state.x.y.z` property access with no conditionals or transforms
- **Trivial action creators** -- simple `{type, payload}` returns or thin API wrappers
- **Trivial reducers** -- only set/clear a single field
- **Empty placeholder tests** -- test body is empty or just mounts a component

### REWRITE as direct unit tests (no rendering):
- **Selectors with logic** -- conditionals, `toUpperCase()`, null checks, computed values
- **Reducers with multiple action types** -- real state merging across several action types
- **Helper functions** -- string checks, transformations, any conditional logic

### REWRITE as RTL component tests:
- All component tests that used `testComponentSnapshotsWithFixtures`

### REWRITE as RTL integration tests:
- Tests that used `IntegrationTestHelper` -- convert to `Provider` + `redux-mock-store` + `fireEvent`

## Step 2: RTL Patterns for This Codebase

### Available matchers
Foreman's Jest setup does NOT include `@testing-library/jest-dom`, so these matchers are **not available**:
- ~~`toBeInTheDocument()`~~ -- use `.toBeTruthy()` instead
- ~~`toBeDisabled()`~~ -- use `.disabled` property: `expect(screen.getByRole('button').disabled).toBe(true)`

### Query priority
Prefer semantic queries that reflect user behavior:
1. `screen.getByRole('button', { name: /Button Text/ })` -- best for interactive elements
2. `screen.getByText(/visible text/)` -- for non-interactive content
3. `container.querySelector('.css-class')` -- only for CSS class checks, no better alternative

### Checking absence
- **Use `queryBy*`**, not `getBy*` -- `getBy` throws when element is absent, `queryBy` returns `null`
- `expect(screen.queryByRole('alert')).toBeNull()` -- semantic, tests what matters
- `expect(screen.queryByText(/Next run:/)).toBeNull()` -- tests absence of specific content
- **Avoid** `expect(container.innerHTML).toBe('')` -- brittle against markup changes

### Shared mocks
Create fresh `jest.fn()` mocks per test to avoid call-count leakage:
```js
// BAD -- shared across tests, counts accumulate
const defaultProps = { onClick: jest.fn() };

// GOOD -- fresh mocks each time
const buildProps = (overrides = {}) => ({
  onClick: jest.fn(),
  ...overrides,
});
```

## Use Shared Mocks from `__mocks__/` Directory

The plugin has a `webpack/__mocks__/foremanReact/` directory with shared manual mocks for Foreman core modules. **Always check this directory before writing inline `jest.mock()` factories.** See: https://github.com/theforeman/foreman/blob/develop/developer_docs/ui-testing-guidelines.asciidoc#plugin-test-configuration-and-setup

### How it works
Call `jest.mock('foremanReact/Some/Module')` **without a factory function**. Jest will automatically find and use the mock file at `webpack/__mocks__/foremanReact/Some/Module.js`.

```js
// BAD -- duplicates what __mocks__ already provides
jest.mock('foremanReact/Root/Context/ForemanContext', () => ({
  useForemanOrganization: () => ({ title: 'Any Organization' }),
}));

// GOOD -- uses shared mock from webpack/__mocks__/foremanReact/Root/Context/ForemanContext.js
jest.mock('foremanReact/Root/Context/ForemanContext');
```

### Available shared mocks (check `webpack/__mocks__/foremanReact/` for current list):
- `Root/Context/ForemanContext.js` -- `useForemanOrganization`, `useForemanSettings`, `useForemanContext`
- `routes/common/PageLayout/PageLayout.js` -- renders `{children}`
- `common/I18n.js`, `common/helpers.js`, `redux/API/index.js`, etc.

### When bare `jest.mock()` does NOT work -- React components
Bare `jest.mock('module')` creates an auto-mock where all exports become `jest.fn()` returning `undefined`. This works fine for **hooks** (undefined is tolerable) but **fails for React components** because React requires `null` or JSX, not `undefined`. If the `__mocks__` file exports a component, you must use an inline factory or `jest.requireActual`:

```js
// This FAILS -- auto-mock returns undefined, React throws "Nothing was returned from render"
jest.mock('foremanReact/routes/common/PageLayout/PageLayout');

// This WORKS -- inline factory returns valid JSX
jest.mock('foremanReact/routes/common/PageLayout/PageLayout', () => ({
  children,
}) => <div>{children}</div>);
```

**Rule of thumb:** bare `jest.mock()` for hooks/utilities, inline factory for React components.

## Step 3: When and How to Mock

### Legitimate reasons to mock child components:
- Child is **Redux-connected** (needs a store with specific state shape)
- Child uses **C3.js / D3.js** (can't render in JSDOM -- e.g., `DonutChart` from `patternfly-react`)
- Child has **deep dependency tree** that's irrelevant to what you're testing
- Child requires **context providers** you'd have to set up (e.g., `Accordion` context for `AccordionItem`)

### The mock-testing-mock anti-pattern:
**Never assert on output that only exists in your mock.** If you mock a component with `data-testid="foo"` and then assert `screen.getByTestId('foo')` -- you're testing your test setup, not your application.

```js
// BAD -- testing the mock
jest.mock('./Child', () => () => <div data-testid="child">Child</div>);
// ...
expect(screen.getByTestId('child')).toBeTruthy(); // proves nothing

// GOOD -- mock isolates, assertion tests real parent logic
jest.mock('./ListItem', () => ({ label }) => <div data-testid="list-item">{label}</div>);
// ...
expect(screen.getAllByTestId('list-item')).toHaveLength(3); // tests parent's iteration logic
expect(screen.getByText('org-label')).toBeTruthy(); // tests parent passes correct props
```

**The rule:** mocking a child to isolate parent logic is fine. Mocking a child and then asserting on the mock's output is not. Ask: "if I remove this assertion, do I lose coverage of real application code?"

### When a component is pure composition glue:
If the component under test is just JSX wiring children together (no conditionals, no logic), and all children are mocked -- the test can only verify trivial things like a CSS class. That's OK. Be honest about what the test covers rather than inflating it with mock assertions.

## Step 4: Common JSDOM Workarounds

### PF4 AccordionItem needs Accordion parent
```js
import { Accordion } from '@patternfly/react-core';
const renderItem = props => render(<Accordion><ListItem {...props} /></Accordion>);
```

### C3.js charts (DonutChart, etc.) -- mock the entire module
```js
jest.mock('patternfly-react', () => ({
  Grid: { Col: ({ children }) => <div>{children}</div> },
  DonutChart: ({ title }) => (
    <div data-testid="donut-chart">
      <span>{title?.primary}</span>
      <span>{title?.secondary}</span>
    </div>
  ),
}));
```
This tests real prop computation (`${completed}%`) through a simplified renderer.

### Components that import children that fail to resolve
```js
jest.mock('../components/CloudPingModal', () => () => null);
```

### Redux-connected components (integration tests)
```js
import { Provider } from 'react-redux';
import configureMockStore from 'redux-mock-store';
import thunk from 'redux-thunk';

const mockStore = configureMockStore([thunk]);
const store = mockStore({
  ForemanRhCloud: {
    inventoryUpload: {
      inventoryFilter: { filterTerm: '' },
    },
  },
});

render(<Provider store={store}><ConnectedComponent /></Provider>);
fireEvent.change(input, { target: { value: 'new_value' } });
const actions = store.getActions();
expect(actions.find(a => a.type === EXPECTED_TYPE)).toBeTruthy();
```

**IMPORTANT:** Match the full Redux state shape expected by selectors. Selectors typically traverse deeply nested paths like `state.ForemanRhCloud.inventoryUpload.inventoryFilter.filterTerm`. A flat mock state will cause `Cannot read properties of undefined` errors.

## Step 5: Workflow

1. **Audit** -- List all remaining snapshot test files. Cross-reference with actual files on disk (JIRA lists go stale).
2. **Categorize** -- DELETE / REWRITE-UNIT / REWRITE-RTL / REWRITE-INTEGRATION for each file.
3. **Work in small batches** -- Write no more than ~3 test files before running them. Iterate on failures immediately.
4. **Delete snap files** -- Remove the `.snap` file and empty `__snapshots__/` directory for each converted test.
5. **Verify** -- After all conversions:
   ```bash
   find webpack/TARGET_AREA -name "*.snap" | wc -l  # expect 0
   grep -r "testComponentSnapshotsWithFixtures\|testActionSnapshotWithFixtures\|testReducerSnapshotWithFixtures\|testSelectorsSnapshotWithFixtures\|IntegrationTestHelper" webpack/TARGET_AREA/ --include="*.js"  # expect no results
   ```

## Mock path gotcha

`jest.mock()` paths are relative to the **test file**, not the component. If the test is in `__tests__/Foo.test.js` and the component imports from `../Components/Bar`, the mock path from the test file is `../../Components/Bar`, not `../Components/Bar`.
