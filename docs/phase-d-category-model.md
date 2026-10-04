# Phase D — the category model (APPROVED 16 Sep 2026)

Reviewed line by line by Tshenolo on behalf of France and Kealeboga. Bucket = which 50/30/20 bar the line counts toward. Kind = what the figure is. `{amount}` and `{pct}` are filled at render time. All hints, prompts and advice are **verbatim**.

## The rule
We never scold. Family support, contributions, giving and church are obligations, never overspending. Where a line is genuinely risky (housing above 35%, minimum debt above 25%) we say what the number is and what it makes harder, not what the member should have done.

## Decided 15 Sep, not reviewed here
1. Money motshelo counts as saving. 2. Moraka leaves Savings and is never summed as saving. 3. The third bar is "Savings & extra debt repayment". 4. Custom lines get a three-way tag.

## Income
| id | Label | Bucket | Kind | Hint | First-budget prompt | Advice |
|---|---|---|---|---|---|---|
| (net row) | Paid into your bank account each month (net pay) | — | income | what reaches your bank account each month. Filled in from your payslip above when you enter it. *(D.3, 25 Sep 2026; was "the amount on your bank statement, not your payslip")* | — *(D.3: removed. It was approved here but never reached the page; the payslip card's own line, "Start with your payslip. What is left after deductions becomes your income below.", does the job.)* | — |
| (free rows) | member-typed | — | income | side work, rent received, a pension, anything that arrives monthly | — | — |
| farm_income | Farm income | — | income (irregular) | what the moraka or masimo brought in this month — cattle or goats sold, produce sold. Not what the herd is worth. | — | Farm income this month is {amount}. It is real income, and because it comes and goes, the budget treats it as a bonus month rather than a salary. |
| motshelo_payout | Motshelo payout | — | income (irregular) | the share-out from your money motshelo, in the month it arrives | — | A motshelo payout is money you saved coming back to you. A good month to top up the emergency fund or a goal before it becomes ordinary money. |

**Income seeding from the profile does not run.** `maybeSeedIncomeFromAssessment()` only seeds a budget whose first row is labelled `Primary Salary`, and since Phase C (`86a57a4`) a new budget's first row carries the net-pay label instead, so a first budget is never prefilled from `profiles.net_income`. Left off deliberately in D.3 (25 Sep 2026): a seeded row would be `typed`, and the payslip could then never fill it. Logged as an open issue.

## From your payslip (reference — never in a bar, never in a total)

**Phase D.3 (25 Sep 2026): the payslip comes first.** The card sits above Income, opens on a first budget or wherever a payslip figure exists, and is otherwise collapsed to its title and the line "Start with your payslip. What is left after deductions becomes your income below." What is left after the deductions entered (gross plus at least one deduction) **fills the net row's `amount`**, which stays the one home for that figure; the row records `src: 'payslip' | 'typed'`. A typed figure is never overwritten: the member sees "Your payslip works out to {left}. Use that figure" and chooses. Nothing in the block enters any total or bar, as before.
| id | Label | Hint | Advice |
|---|---|---|---|
| gross | Gross pay | before anything is taken off | — |
| paye | PAYE | income tax | — |
| pension | Pension (your contribution) | your share, not your employer's | {amount} a month is already going to your retirement before you see it. That counts. |
| medical | Medical aid (your share) | — | Your medical aid is already in place. |
| loans | Loan repayments deducted from salary | never reaches your account, but it is still debt | This is counted in your debt-to-income with everything else you owe. |
| other | Other deductions | union, garnishee, staff loans, anything else on the slip | — |

## Needs (bucket: need)
| id | Label | Hint | First-budget prompt | Advice |
|---|---|---|---|---|
| housing | Housing & Rent | rent or bond, plus levies and rates | Rent or bond — whatever keeps the roof over you. | Housing is {pct}% of what you earn. Above about 35% it starts crowding out everything else, so it is worth knowing rather than worrying about. |
| utilities | Utilities | water, electricity, and the data you cannot work without | — | — |
| food | Food & Groceries | what you spend feeding your household in a month | Groceries for the household, not meals out — those have their own line. | Food is {pct}% of income. Groceries are one of the few large lines with room to move, if you want it. |
| motshelo_goods **(new)** | Food or goods motshelo | your monthly contribution to a groceries or toiletries motshelo | — | Your goods motshelo is {amount}. It is groceries paid in advance, so it counts as food, not as saving. |
| transport | Transport | fuel, combi fares, taxis, car upkeep | — | — |
| health | Health & Medical | medicines, doctor visits and anything medical aid does not cover | — | — |
| childcare | Child / Education | school fees, uniforms, crèche, transport to school | School fees and anything that comes with them. | School fees are {pct}% of income. It is one of the few costs worth protecting when money is tight. |
| family_support **(new)** | Family support | money to parents, siblings or relatives you support. Choose "fixed" if it is the same every month, or "varies" and enter what you set aside for it. | Many of us send money home. Put it here so your budget tells the truth about your month. | Family support is {amount} a month. It is an obligation, and it is counted as one — not as spending to cut. |
| contributions **(new)** | Contributions | what you set aside for funerals, weddings, baby showers and workplace collections. Most months something comes up. | Set aside something for this month's contributions — a funeral, a wedding, the office collection — so they do not come out of the food money. | You set aside {amount} for contributions. When a month passes without one, that amount can move to savings. |
| helper | Helper | domestic worker, garden help — wages and their transport | — | Employing someone is a wage they depend on. It belongs in Needs, not Wants. |
| insurance | Insurance | funeral cover, life, car, home — not medical aid | — | — |
| moraka **(moved from Savings)** | Farm costs (moraka & masimo) | feed, herding, vet, dipping, seed, ploughing, fuel to the farm. Not the value of the herd or the land. | Running costs of the cattle post or the fields — not what the herd is worth. | Farm costs are {amount} a month. The herd and the land may be assets; keeping them is a cost, and it is counted as one. |
| debt_min | Minimum debt payments | the minimum you must pay each month, across every loan | Only the minimums. Anything extra you choose to pay goes in Extra debt repayment. | Minimum debt payments are {pct}% of income. Above about 25% this is what makes a month feel tight even when nothing has gone wrong. |

## Wants (bucket: want)
| id | Label | Hint | First-budget prompt | Advice |
|---|---|---|---|---|
| entertain | Entertainment | — | — | — |
| dining | Dining out | restaurants, takeaways, lunch at work | — | — |
| shopping | Shopping & clothing | — | — | — |
| personal | Personal care | hair, grooming, salon | — | — |
| subscript | Subscriptions | streaming, gym, apps — the ones that renew without asking | Worth listing: subscriptions are the easiest thing to forget you are paying for. | Subscriptions add up to {amount} a month. Worth a look at which ones you still use. |
| travel | Travel & holidays | — | — | — |
| hobbies | Hobbies & leisure | — | — | — |

Group advice when Wants are large: "Wants are {pct}% of income. There is nothing wrong with that if the rest of your month works — it is the first place to look only if you want it to be."

## Savings & investments (bucket: save)
| id | Label | Hint | First-budget prompt | Advice | In monthly_savings? |
|---|---|---|---|---|---|
| emfund | Emergency fund | what you put aside each month for the month that goes wrong | Even P100 a month starts this. The amount matters less than it existing. | No emergency fund yet. Three months of essentials is {amount} — a target, not a demand. | yes |
| retirement | Retirement / pension | what you choose to put away, on top of any pension off your payslip | — | You are putting {amount} toward retirement by choice, plus {amount} off your payslip. | yes |
| invest | Investments | unit trusts, shares, a fixed deposit, an asset manager | — | — | yes |
| goals | Goal savings | money set aside for something specific — see the goal types below | — | — | yes |
| motshelo **(relabelled)** | Money motshelo | your monthly contribution to the group. Enter the payout under Income when it arrives. | A motshelo is saving. It counts here. | Your motshelo is {amount} a month. That is saving, and it is counted as saving. | **yes (new)** |
| debt_extra | Extra debt repayment | what you pay above the minimum, by choice | — | You are paying {amount} above your minimums. That is the fastest interest you will ever save. | **no** — third bar only |

## Other (bucket: tagged by the member — question 1, option c)
| id | Label | Hint | Advice | Bucket |
|---|---|---|---|---|
| gifts | Giving (church, tithe, gifts) | tithe or church giving, and gifts you give. Money to family goes under Family support. | You give {amount} a month. For most people this is a commitment, not a luxury, and the budget treats it that way. | asked on first non-zero entry; untagged = no bar |
| misc | Miscellaneous | anything that fits nowhere else | — | asked on first non-zero entry; untagged = no bar |

## Custom lines (approved)
| Rule | Behaviour |
|---|---|
| Tag stored | on the custom line, per budget month |
| Untagged | in the expense total, in no bar, exactly as today; never guessed |
| Copy to next month | tag travels with the line |
| Tag = need / want | counts toward that bar |
| Tag = saving | counts toward the third bar and into monthly_savings |
| Rename | tag kept |
| Advice | custom lines are never named in advice copy |

The question, asked once (approved wording): **"Is this a need, a want, or saving?"** — *Need*: you could not stop paying it this month. *Want*: you choose it, and could pause it. *Saving*: the money is still yours afterwards.

## Goal types (Goal Planner)
| id | Label | Hint | Copy |
|---|---|---|---|
| goal_bogadi | Bogadi | what you plan to set aside toward bride price, and by when | Bogadi is a large, known cost with a date. Treating it as a goal means the money is there when the families sit down, not borrowed the month before. |
| goal_livestock | Livestock | saving to buy cattle, goats or sheep — by head, with today's price | Saving toward livestock is saving toward an asset. Once bought, the animals move to your assets, and their upkeep moves to Farm costs. |

## The six questions — answers
1. Giving and Miscellaneous: **option c** — the member tags them (three-way question on first non-zero entry); untagged stays in no bar.
2. Farm costs → **Needs**.
3. Family support fixed / varies with provision: **yes**.
4. Re-tagging built-ins: **no**; custom lines, Giving and Miscellaneous only.
5. Expense Tracker adopts this list: **yes, as Phase D.2**.
6. Three-way question wording: **approved**.

## Phase D.3: double-counting warnings (approved 25 Sep 2026, verbatim)
Words only. Shown when the payslip figure is above zero, while the member is in the line or once the line has a figure. Muted, never red, never blocking.

| Budget line | Shows when | Wording |
|---|---|---|
| debt_min | payslip loans > 0 | Your payslip already takes {amount} in loan repayments. / Only add loans here that you pay from your bank account. / Adding a payslip loan again would count it twice. |
| retirement | payslip pension > 0 | {amount} already goes to your pension through your payslip. / Add only what you pay on top by choice, such as a retirement annuity. / Adding the payslip amount here would count it twice. |
| health | payslip medical > 0 | Your medical aid of {amount} comes off your payslip. / Add only medical costs you pay yourself, like gap payments or pharmacy. |
| insurance | payslip other > 0 | Some cover, like funeral policies, may already come off your payslip. / Only add policies you pay from your bank account. |

Hints and first-budget prompts in this document now show only while the member is in that line (D.3). Their wording is unchanged.
