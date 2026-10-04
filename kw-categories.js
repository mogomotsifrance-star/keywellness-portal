/* Key Wellness — the category model, in ONE place.
 *
 * Phase D approved a single Botswana category list (see
 * docs/phase-d-category-model.md, 16 Sep 2026). Phase D.2 made the Expense
 * Tracker adopt it — and the tracker is a standalone page, so the only way to
 * have one list rather than two copies of one list is to put it here and load
 * it from both.
 *
 * That is the whole point of D.2: before it, the tracker carried its own 13
 * expense and 5 income categories which did not match the budget's, so a
 * member who logged daily spending and kept a budget had two category models
 * and no way to compare them.
 *
 * Loaded as a classic script by budget_planner.html and expense_tracker.html,
 * so every name below is a global. Anything reading these must not mutate
 * them.
 *
 * ADDING A CATEGORY: add it here, with its bucket, and add its hint and any
 * first-budget prompt. Both pages pick it up. Do not add a category to one
 * page only — that is the defect this file exists to prevent.
 */

// Phase D — the approved Botswana category model.
// Spec: docs/phase-d-category-model.md (APPROVED 16 Sep 2026). Every hint,
// first-budget prompt and advice sentence in this file is verbatim from it.
//
// `bucket` is the arithmetic; `group` is only where the line is drawn on
// screen. The 50/30/20 bars and calcTotals() read BUCKET. They used to read
// group, which is why the Other group — Giving, Miscellaneous and every custom
// line — was counted in the expense total and appeared in no bar at all, so
// the three bars never added up to what the member spends.
//
// `bucket: null` means the member has not told us yet (Giving, Miscellaneous,
// an untagged custom line). Never guessed, never defaulted: an untagged line
// stays in the total and in no bar, and is asked about again on the next save.
//
// EVERY ID IS UNCHANGED, so no stored budget needs migrating. `moraka` moves
// group and bucket but keeps its id and its amount.
const KW_EXPENSE_GROUPS = [
  {
    id:'needs', name:'Needs', icon:'\ud83c\udfe0', color:'#163561',
    cats:[
      {id:'housing',        name:'Housing & Rent',            bucket:'need'},
      {id:'utilities',      name:'Utilities',                 bucket:'need'},
      {id:'food',           name:'Food & Groceries',          bucket:'need'},
      {id:'motshelo_goods', name:'Food or goods motshelo',    bucket:'need'},
      {id:'transport',      name:'Transport',                 bucket:'need'},
      {id:'health',         name:'Health & Medical',          bucket:'need'},
      {id:'childcare',      name:'Child / Education',         bucket:'need'},
      {id:'family_support', name:'Family support',            bucket:'need'},
      {id:'contributions',  name:'Contributions',             bucket:'need'},
      {id:'helper',         name:'Helper',                    bucket:'need'},
      {id:'insurance',      name:'Insurance',                 bucket:'need'},
      // Moved out of Savings 16 Sep. A cattle post is a store of wealth; the
      // feed, dipping and fuel that keep it are a cost, and members who told
      // us they "save" through cattle were having a farm's running costs
      // counted as savings.
      {id:'moraka',         name:'Farm costs (moraka & masimo)', bucket:'need'},
      {id:'debt_min',       name:'Minimum debt payments',     bucket:'need'},
    ]
  },
  {
    id:'wants', name:'Wants', icon:'\ud83c\udfac', color:'#D97706',
    cats:[
      {id:'entertain',  name:'Entertainment',       bucket:'want'},
      {id:'dining',     name:'Dining out',          bucket:'want'},
      {id:'shopping',   name:'Shopping & clothing', bucket:'want'},
      {id:'personal',   name:'Personal care',       bucket:'want'},
      {id:'subscript',  name:'Subscriptions',       bucket:'want'},
      {id:'travel',     name:'Travel & holidays',   bucket:'want'},
      {id:'hobbies',    name:'Hobbies & leisure',   bucket:'want'},
    ]
  },
  {
    id:'savings', name:'Savings & Investments', icon:'\ud83d\udcb0', color:'#1A8C5B',
    cats:[
      {id:'emfund',     name:'Emergency fund',        bucket:'save'},
      {id:'retirement', name:'Retirement / pension',  bucket:'save'},
      {id:'invest',     name:'Investments',           bucket:'save'},
      {id:'goals',      name:'Goal savings',          bucket:'save'},
      {id:'motshelo',   name:'Money motshelo',        bucket:'save'},
      // In the third bar, never in monthly_savings — which is why that bar is
      // labelled "Savings & extra debt repayment". Paying debt down faster is
      // good; it is not money you still have.
      {id:'debt_extra', name:'Extra debt repayment',  bucket:'save'},
    ]
  },
  {
    id:'other', name:'Other', icon:'\ud83d\udccb', color:'#64748B',
    cats:[
      // Tagged by the member on first non-zero entry (question 1, option c).
      {id:'gifts',      name:'Giving (church, tithe, gifts)', bucket:null},
      {id:'misc',       name:'Miscellaneous',                 bucket:null},
    ]
  },
];

// Hints, first-budget prompts and advice, verbatim from the approved model.
// Keyed by category id; absent means the line carries none.
const KW_CAT_HINT = {
  housing:'rent or bond, plus levies and rates',
  utilities:'water, electricity, and the data you cannot work without',
  food:'what you spend feeding your household in a month',
  motshelo_goods:'your monthly contribution to a groceries or toiletries motshelo',
  transport:'fuel, combi fares, taxis, car upkeep',
  health:'medicines, doctor visits and anything medical aid does not cover',
  childcare:'school fees, uniforms, cr\u00e8che, transport to school',
  family_support:'money to parents, siblings or relatives you support. Choose "fixed" if it is the same every month, or "varies" and enter what you set aside for it.',
  contributions:'what you set aside for funerals, weddings, baby showers and workplace collections. Most months something comes up.',
  helper:'domestic worker, garden help \u2014 wages and their transport',
  insurance:'funeral cover, life, car, home \u2014 not medical aid',
  moraka:'feed, herding, vet, dipping, seed, ploughing, fuel to the farm. Not the value of the herd or the land.',
  debt_min:'the minimum you must pay each month, across every loan',
  dining:'restaurants, takeaways, lunch at work',
  personal:'hair, grooming, salon',
  subscript:'streaming, gym, apps \u2014 the ones that renew without asking',
  emfund:'what you put aside each month for the month that goes wrong',
  retirement:'what you choose to put away, on top of any pension off your payslip',
  invest:'unit trusts, shares, a fixed deposit, an asset manager',
  goals:'money set aside for something specific \u2014 see the goal types below',
  motshelo:'your monthly contribution to the group. Enter the payout under Income when it arrives.',
  debt_extra:'what you pay above the minimum, by choice',
  gifts:'tithe or church giving, and gifts you give. Money to family goes under Family support.',
  misc:'anything that fits nowhere else',
};

// Shown under the field on a member's FIRST budget only.
const KW_CAT_FIRST_PROMPT = {
  housing:'Rent or bond \u2014 whatever keeps the roof over you.',
  food:'Groceries for the household, not meals out \u2014 those have their own line.',
  childcare:'School fees and anything that comes with them.',
  family_support:'Many of us send money home. Put it here so your budget tells the truth about your month.',
  contributions:'Set aside something for this month\u2019s contributions \u2014 a funeral, a wedding, the office collection \u2014 so they do not come out of the food money.',
  moraka:'Running costs of the cattle post or the fields \u2014 not what the herd is worth.',
  debt_min:'Only the minimums. Anything extra you choose to pay goes in Extra debt repayment.',
  subscript:'Worth listing: subscriptions are the easiest thing to forget you are paying for.',
  emfund:'Even P100 a month starts this. The amount matters less than it existing.',
  motshelo:'A motshelo is saving. It counts here.',
};

const KW_ALL_CATS   = KW_EXPENSE_GROUPS.flatMap(g=>g.cats);
const KW_CAT_MAP    = Object.fromEntries(KW_ALL_CATS.map(c=>[c.id,c]));
const KW_GROUP_MAP  = Object.fromEntries(KW_EXPENSE_GROUPS.map(g=>[g.id,g]));
const KW_BUCKET_OF = Object.fromEntries(KW_ALL_CATS.map(c=>[c.id, c.bucket ?? null]));
// The two built-ins the member tags, and the only ones that may be re-tagged.
// Every other built-in is fixed (question 4): a member re-tagging `housing` as
// a Want would produce figures nothing downstream could reason about.
const KW_TAGGABLE_BUILTINS = ['gifts','misc'];

/* ── Group presentation ───────────────────────────────────────────────────
 * The tracker's donut, filter pills and breakdown need a colour and an icon
 * per slice. Budget categories carry neither, and inventing 28 of each would
 * be 28 more things to keep in step. So the tracker colours BY GROUP, which
 * is also the more useful chart: Needs / Wants / Savings proportions say
 * something, where 13 arbitrary colours do not.
 */
const KW_GROUP_OF = Object.fromEntries(
  KW_EXPENSE_GROUPS.flatMap(g => g.cats.map(c => [c.id, g.id]))
);
function kwGroupMeta(groupId) {
  return KW_EXPENSE_GROUPS.find(g => g.id === groupId) || KW_EXPENSE_GROUPS[KW_EXPENSE_GROUPS.length - 1];
}

/* ── Income ───────────────────────────────────────────────────────────────
 * The budget models income as free-text rows plus two recognised ids, so
 * there is no income CATEGORY list for the tracker to adopt. The tracker
 * keeps its five, and gains the two recognised ones under the budget's own
 * ids — so a cattle sale logged here and a cattle sale budgeted there are the
 * same thing.
 */
const KW_INCOME_CATS = [
  { id:'salary',          name:'Salary',          icon:'\ud83d\udcbc' },
  { id:'business',        name:'Business',        icon:'\ud83c\udfe2' },
  { id:'rental',          name:'Rental',          icon:'\ud83c\udfd8\ufe0f' },
  { id:'freelance',       name:'Freelance',       icon:'\ud83d\udcbb' },
  { id:'farm_income',     name:'Farm income',     icon:'\ud83c\udf3e' },
  { id:'motshelo_payout', name:'Motshelo payout', icon:'\ud83e\udd32' },
  { id:'other_in',        name:'Other',           icon:'\u2795' },
];

/* ── Phase D.2 migration map ──────────────────────────────────────────────
 * The tracker's old ids, and where each one lands. `family` is the only one
 * the member is asked about: money to relatives is Family support, but some
 * people mean church and gifts by it, so the question is offered once, to
 * members who actually have family entries. Everything else is settled.
 *
 * An id NOT in this map is never dropped — see kwMigrateCategory().
 */
const KW_TRACKER_CAT_MIGRATION = {
  food:'food', transport:'transport', housing:'housing', utilities:'utilities',
  health:'health', entertain:'entertain', shopping:'shopping', personal:'personal',
  education:'childcare',      // the budget calls it Child / Education
  debt:'debt_min',            // minimums; extra repayment is its own budget line
  savings:'goals',            // the tracker's one savings bucket is goal savings
  family:'family_support',    // default; Giving offered once (see above)
  other:'misc',
};

/* Map one stored tracker category id onto the shared model.
 *
 * Returns { id, wasUnknown, oldId }. An id the map does not know is KEPT as it
 * is and flagged, never dropped and never guessed at: a member's logged
 * spending is not ours to delete because a category was renamed, and quietly
 * filing it under "Other" would be inventing a fact about their money. The
 * tracker renders an unknown id as "Uncategorised (was: <id>)" with a one-click
 * fix.
 */
function kwMigrateCategory(oldId, opts) {
  const o = opts || {};
  if (!oldId) return { id: oldId, wasUnknown: false, oldId };
  // Already a live category (a second pass, or an entry logged after D.2).
  if (KW_CAT_MAP[oldId] || KW_INCOME_CATS.some(c => c.id === oldId)) {
    return { id: oldId, wasUnknown: false, oldId };
  }
  if (oldId === 'family' && o.familyTo) {
    return { id: o.familyTo, wasUnknown: false, oldId };
  }
  const mapped = KW_TRACKER_CAT_MIGRATION[oldId];
  if (mapped) return { id: mapped, wasUnknown: false, oldId };
  return { id: oldId, wasUnknown: true, oldId };
}

/* The stamp that makes the migration run exactly once per payload.
 *
 * It is checked and written per SAVED PAYLOAD, not per device: the Supabase
 * restore overwrites localStorage wholesale, so a row written before D.2 can
 * land on a device that has already migrated. Stamping the payload means that
 * row is migrated when it arrives, and a migrated one is left alone.
 */
const KW_CAT_MODEL_STAMP = 'phase-d';
