# Task 16a report

Branch plan3a-task16a (from c3b6daf). Views: BacklogView (tree table, inspector with form/check/branch/deps/events/moves), BoardView (6 columns, owner-allowed drag), InboxView (PENDING/FYI/RECENTLY DECIDED cards, document, rescind popover), ItemEditorSheet, OrgPreview, NewCompanySheet (Agents, pack, preview, experimental note), TopBar (sprint line, AUTONOMY + "Switch to Auto?" alert, usage + pace, WHY chip popover, company settings popover with auto-merge toggle and by-mode budget), EngineBanner (hold in danger + Retry), Sidebar rows, MenuBar stall line, OwnerNotifier (UNUserNotificationCenter, ask-<id>-<remindCount>, click opens Inbox), owner time zone at all TimeText sites, mode chip / Reports to / Team / Reports / ACTING chip in Agents.

PNGs (.superpowers/ui/):
- task16-backlog.png: Initech backlog, epic Streaks, indented Streak counter, bug; SHOWING 3 OF 3; top bar with No active sprint, AUTONOMY IMPORTANT, usage, pace, WHY chip.
- task16-board.png: six columns Backlog..Done with the three cards in Backlog.
- task16-inbox.png: A-1 (kind title "Brief & architecture" for a 6-seat company) "Approved by @ceo", inline PRD with link as plain text; A-2 pricing with reserved warning chip.
- task16-newco.png: Agents stepper 6, pack picker, org preview with qa vacancy.
- task16-item.png: INITE-2 inspector with check line `$ test -f streak.txt`, parent, move buttons, edit form.

Model deltas: BoardColumns gets a Backlog column; internal line "Approved by @x"; notification id ask-<id>-<n>; system DM text; AppModel.afterTick hook; ItemDetail loader; OwnerMoves; setAutoMergeSmall; confirmReportedPlan; --company launch option. Scripts: seed Initech (uses --by/--document, plus ceo-decide A-2 so the reserved ask reaches the owner), fake-claude answers the doctor's --effort/--max-budget-usd flags, the mode-canary control session and init agents list, smoke-app expects companies=3 agents=10.
