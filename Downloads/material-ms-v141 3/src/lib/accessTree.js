// Single source of truth for access control, down to each screen.
// Each leaf "key" is what gets stored per-user. A user with a module ticked
// but specific leaves unticked sees only the ticked leaves.
//
// Keys are namespaced: "<page>:<leaf>" so they're globally unique.
// Voucher leaves use the voucher_type as the leaf key.

export const APP_TREE = [
  { page: "Dashboard", label: "Dashboard", always: true, groups: [] },
  {
    page: "Vouchers", label: "Vouchers", groups: [
      {
        heading: "Create / Post", items: [
          ["PURCHASE_ORDER", "Purchase order"], ["PURCHASE", "Purchase"],
          ["DEBIT_NOTE_RC", "Purchase return (DN) - RC"], ["DC_OUT_JW", "DC Out (JW)"],
          ["RC_IN_JW", "RC In (JW)"], ["SALES_ORDER", "Sales Order"], ["SALES_LOCAL", "Sales (Local)"], ["RESALE", "Resale"],
          ["CREDIT_NOTE", "Sales return (CN)"], ["PROCESS_REJECTION", "Process rejection"],
          ["SCRAP_SALES", "Scrap sales"], ["MATERIAL_REJECTION", "Material Rejection"],
          ["DEBIT_NOTE_DN", "Purchase return (DN)"], ["DC_OUT_RET", "DC Out (Returnable)"],
          ["RC_IN_RET", "RC In (Returnable)"], ["DC_OUT_REPLACE", "DC out (Replacement)"],
          ["RC_IN_REPLACE", "RC In (Replacement)"], ["DC_OUT_NONRET", "DC Out (Non returnable)"],
          ["PRODUCTION", "Production log"],
        ]
      },
    ]
  },
  {
    page: "Books", label: "Books", groups: [
      {
        heading: "Registers", items: [
          ["PURCHASE_ORDER", "Purchase order"], ["PURCHASE", "Purchase"],
          ["DEBIT_NOTE_RC", "Purchase return (DN) - RC"], ["DC_OUT_JW", "DC Out (JW)"],
          ["RC_IN_JW", "RC In (JW)"], ["SALES_ORDER", "Sales Order"], ["SALES_LOCAL", "Sales (Local)"], ["RESALE", "Resale"],
          ["CREDIT_NOTE", "Sales return (CN)"], ["PROCESS_REJECTION", "Process rejection"],
          ["SCRAP_SALES", "Scrap sales"], ["MATERIAL_REJECTION", "Material Rejection"],
          ["DEBIT_NOTE_DN", "Purchase return (DN)"], ["DC_OUT_RET", "DC Out (Returnable)"],
          ["RC_IN_RET", "RC In (Returnable)"], ["DC_OUT_REPLACE", "DC out (Replacement)"],
          ["RC_IN_REPLACE", "RC In (Replacement)"], ["DC_OUT_NONRET", "DC Out (Non returnable)"],
        ]
      },
    ]
  },
  {
    page: "Inventory", label: "Inventory", groups: [
      { heading: "Stock Position", items: [["summary", "Stock Summary"], ["partledger", "Part Ledger"], ["stockview", "Stock Statement / Ledger"]] },
      { heading: "Movements", items: [["transfer", "Stock Transfer"]] },
      { heading: "Maintenance", items: [["recon", "Physical Stock Recon"], ["opening", "Opening Stock"]] },
    ]
  },
  {
    page: "Database", label: "Database", groups: [
      { heading: "Master Data", items: [["ledger", "Ledger"], ["part", "Part"], ["pricing", "Part Pricing"]] },
      { heading: "Reports", items: [["burr", "Burr Generation Report"]] },
    ]
  },
  {
    page: "Administration", label: "Administration", adminOnly: true, groups: [
      { heading: "Approvals", items: [["price", "Price Approval"], ["overdue", "Overdue DC Approval"], ["rec", "Rec Copy Approval"], ["mark", "Mod & Del Requests"]] },
      { heading: "Logs", items: [["undo", "Transaction Log"], ["audit", "Audit Log"]] },
      { heading: "Configuration", items: [["users", "User Management"], ["settings", "Settings"], ["machine", "Machine Config"], ["period", "Period Close"]] },
    ]
  },
];

export const leafKey = (page, leaf) => `${page}:${leaf}`;

// All leaf keys in the app (used for "select all").
export function allLeafKeys() {
  const out = [];
  APP_TREE.forEach(m => m.groups.forEach(g => g.items.forEach(([k]) => out.push(leafKey(m.page, k)))));
  return out;
}

// Parse a stored access string ("ALL" or comma list of "page" and "page:leaf")
// into a Set. "ALL" -> null meaning everything.
export function parseAccess(str) {
  if (!str || str === "ALL") return null;
  return new Set(str.split(",").map(s => s.trim()).filter(Boolean));
}

// Is a whole page visible? (page name present, OR any of its leaves present)
export function pageAllowed(accessSet, page) {
  if (!accessSet) return true;
  if (accessSet.has(page)) return true;
  return APP_TREE.find(m => m.page === page)?.groups.some(g => g.items.some(([k]) => accessSet.has(leafKey(page, k)))) || false;
}

// Is a specific leaf visible?
export function leafAllowed(accessSet, page, leaf) {
  if (!accessSet) return true;
  if (accessSet.has(page)) return true;            // whole-page grant
  return accessSet.has(leafKey(page, leaf));
}
