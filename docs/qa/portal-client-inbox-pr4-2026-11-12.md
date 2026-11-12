# Client Inbox acceptance (PR 4)

Built on main 8f772921 using the portal design sections 3–5/9 and the November 12 MoSa decisions. This is staff discovery/reply and client unread visibility; no payroll submission/import, email activation or deployment is included.

The inbox stays independent of selected company. Its server query enforces organization, active live clients and unexpired assignments. Accountants need a client-management grant to see employee changes. Signed seek cursors retain an activity snapshot and microsecond ordering; refresh replaces the visible window and pages dedupe by kind/id. Personal unread is separate from work waiting: an open client-last conversation, unreviewed upload or pending employee request. Reading never completes work. Existing active client uploads start unreviewed; no prior staff acknowledgment is inferred.

Agent-executed synthetic browser acceptance passed at CSS 390×844 and 1280×900:

- Start on First Client, find Second Client work, open the exact conversation, reply, return with client/kind/status filters and scroll preserved (950 px phone; 1,100 px desktop). Saved replies remain in the selected company's exact thread.
- Deactivate Second Client and Refresh: zero rows/counts. Inactive Third Client is excluded throughout.
- Walk 56 document rows without repeats; open the exact older PDF; keep personal receipt distinct from explicit staff review; find it through bounded server search beyond the initial library page; open the exact employee request.
- Staff nav/dashboard show separate authorized work/unread totals. Client Messages badge comes from its count endpoint; hidden mobile prefetch keeps the item unread until the conversation is shown. Client replies persist at both widths.

Fixed during QA: Dashboard's parent route was also highlighted; preview close removed the review action; a deep-linked document inherited a long list scroll. Regression coverage and both-width retests accompany the fixes.

Live invalidation also brought older Second Client work to the top while First Client stayed selected, with 25 unique rows after repeated events. This extra transport check used an owned synthetic org_admin because the existing auth-disabled Cable fallback can choose a different fixture user; core staff journeys used a manager. Real Clerk/Cable authentication, real phone keyboards, Safari and real email delivery are not certified here. Page-view tracking remains in the existing global route observer for all new destinations.

Detailed ledger, screenshots, fixture scripts and independently saved outcomes are in the authorized local output directory `output/payroll-portal-pr4-20261112` under the ShimizuTechnology root. Email remained disabled with zero sent deliveries. Exact final automated and reviewer results are recorded in the PR and handoff. No production records were used.
