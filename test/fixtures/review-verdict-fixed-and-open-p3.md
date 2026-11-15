## verify (fiber-4844 reduced fixture)

FIX-INCOMPLETE. Two P2 mutant findings are fixed at HEAD. Open P3 findings remain.

Fixed:

- **P2 `src/settings_view.rs:560:68`, `open_on` `==`→`!=`: fixed.** The test now asserts the Advanced tab.
- **P2 `src/settings_view.rs:1927:42`, `choose` `&&`→`||`: fixed.** The non-editor key does not add a wait flag.
- **P2 `src/settings_view.rs:1930:12`, editor mode guard: fixed.** The call now checks editor mode.
- **P3 `src/settings_view_tests.rs:27`, doc comment: fixed.** The value helper has its documentation restored.

**Open:**

- **P3 `src/settings_view_tests.rs:30`, wrapper placement: the doc comment remains on the wrapper.**
- **P3 `src/notices.rs:545`, single-caller pass-through: inline the call.**

**New**

- **P3 `src/settings_view_tests.rs:2973`, stale test name: rename it to match the Advanced tab.**

### Not judged

- P2 `src/event_loop.rs:343`: split this finding to another ticket.

FIX-INCOMPLETE
