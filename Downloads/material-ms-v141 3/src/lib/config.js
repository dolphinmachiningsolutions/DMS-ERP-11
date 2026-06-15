import { createClient } from "@supabase/supabase-js";

export const SUPABASE_URL = "https://knvfhynvywwqpkomdhlb.supabase.co";
export const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtudmZoeW52eXd3cXBrb21kaGxiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA0MDU1MTAsImV4cCI6MjA5NTk4MTUxMH0.Ig3eNbPuTtFn6UykZkqv_7YjqytAogiI-rKumEZvklc";
export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

/* Stock buckets (exact names) */
export const BUCKETS = { RC:"Raw Casting", RCJW:"Raw @ Coating", CC:"Coated Casting",
  MG:"Machined Goods", PR:"Process Rejection", MR:"Material Rejection",
  JOBOUT:"Sent Out (expected back)", VENDOR:"Vendor", CUSTOMER:"Customer", DCNOUT:"Sent Out (non-returnable)" };

/* Voucher modules — keys are EXACT, labels match spec wording */
export const VOUCHERS = {
  PURCHASE_ORDER:    { label:"Purchase Order", ledger:"Vendor RM", from:null,to:null, single:false, maxLines:10, ref:null, priceType:"purchase", priceLocked:true, validThru:"5th", header:["valid_thru"], mandatory:["no","date","ledger_id","part","qty"], cols:["part","qty","uom","unit_price","basic_value","narration"], idPrefix:"PO" },
  PURCHASE:          { label:"Purchase", ledger:"Vendor RM", from:"VENDOR",to:"RC", single:false, maxLines:10, ref:"PURCHASE_ORDER", refChained:true, partsByVendor:true, priceType:"purchase", priceManual:true, header:["posting_date"], qtyField:"actual_qty", packages:true, priceCheck:true, mandatory:["no","date","posting_date","ledger_id","part","ref","invoice_qty","actual_qty","unit_price"], cols:["part","ref","invoice_qty","actual_qty","uom","unit_price","po_price","basic_value","narration"], idPrefix:"PUR" },
  DEBIT_NOTE_RC:     { label:"Purchase Return (RC)", dateTodayOnly:true, noNumber:true, ledger:"Vendor RM", from:"RC",to:"VENDOR", single:true, ref:null, priceType:"purchase", priceLocked:true, packages:true, pkgQtyField:"qty", cols:["part","lot","qty","unit_price","basic_value","uom","narration"], idPrefix:"DNRC" },
  DC_OUT_JW:         { label:"DC Out (JW)", ledger:"Vendor JW", from:"RC",to:"RCJW", single:true, maxLines:1, ref:null, priceType:null, numberScheme:"dcjw", dateTodayOnly:true, validThru:"due3", validThruLabel:"Due date", allParts:true, packages:true, pkgQtyField:"qty", mandatory:["no","date","valid_thru","ledger_id","part","qty"], header:["valid_thru"], cols:["part","lot","qty","uom","narration"], idPrefix:"DCO" },
  RC_IN_JW:          { label:"RC In (JW)", ledger:"Vendor JW", from:"RCJW",to:"CC", single:true, maxLines:1, ref:"DC_OUT_JW", numberScheme:"rcjw", allParts:true, dcAllocation:true, packages:true, packagesView:true, priceType:null, header:["posting_date"], qtyField:"actual_qty", mandatory:["no","date","posting_date","ledger_id","part","invoice_qty","actual_qty"], cols:["part","lot","invoice_qty","actual_qty","uom","narration"], idPrefix:"RCI" },
  SALES_ORDER:       { label:"Sales Order", ledger:"Customer", from:null,to:null, single:false, maxLines:10, ref:null, priceType:"sale", priceLocked:true, validThru:"eom", header:["valid_thru"], mandatory:["no","date","ledger_id","part","qty"], cols:["part","qty","uom","unit_price","basic_value","narration"], idPrefix:"SO" },
  RESALE:            { label:"Resale", ledger:"Customer", from:"MG",to:"CUSTOMER", single:true, maxLines:1, noNumber:true, partsByCustomer:true, priceType:"sale", simplePackages:true, mandatory:["ledger_id","part","qty","packages"], cols:["part","qty","pkg_count","uom","unit_price","basic_value","lb_value","narration"], idPrefix:"RSL" },
  SALES_LOCAL:       { label:"Sales", ledger:"Customer", from:"MG",to:"CUSTOMER", single:true, maxLines:1, noNumber:true, ref:"SALES_ORDER", refChained:true, partsByCustomer:true, priceType:"sale", priceFromRef:true, simplePackages:true, mandatory:["ledger_id","part","ref","qty","packages"], cols:["part","ref","qty","pkg_count","uom","unit_price","basic_value","lb_value","narration"], idPrefix:"SAL" },
  CREDIT_NOTE:       { label:"Sales Return", ledger:"Customer", from:"CUSTOMER",to:null, single:false, ref:null, priceType:null, disposition:true, cols:["part","qty","uom","disposition","unit_price","basic_value","narration"], idPrefix:"CN" },
  PROCESS_REJECTION: { label:"Process Rejection", ledger:null, from:"MG",to:"PR", single:false, maxLines:50, noNumber:true, date2back:true, allParts:true, manualQty:true, autoWeightOut:true, defectDropdown:true, totalsRow:true, mandatory:["date","part","qty","defect_type"], cols:["part","qty","weight","defect_type","narration"], idPrefix:"PRJ" },
  SCRAP_SALES:       { label:"Scrap Sales", ledger:"Customer", from:"PR",to:"CUSTOMER", single:false, ref:null, priceType:null, noNumber:true, allParts:true, autoWeightOut:true, cols:["part","lot","qty","weight","uom","narration"], idPrefix:"SCR" },
  MATERIAL_REJECTION:{ label:"Material Rejection", ledger:null, from:"MG",to:"MR", single:false, maxLines:50, noNumber:true, date2back:true, allParts:true, manualQty:true, autoWeightOut:true, defectDropdown:true, totalsRow:true, mandatory:["date","part","qty","defect_type"], cols:["part","qty","weight","defect_type","narration"], idPrefix:"MRJ" },
  DEBIT_NOTE_DN:     { label:"Purchase Return (MR)", ledger:"Vendor RM", from:"MR",to:"VENDOR", single:false, ref:null, priceType:"purchase", priceLocked:true, noNumber:true, autoWeightOut:true, packages:true, pkgQtyField:"qty", cols:["part","lot","qty","uom","unit_price","basic_value","weight","narration"], idPrefix:"DN" },
  DC_OUT_RET:        { label:"DC Out (Returnable)", ledger:"Vendor JW", ledgerFreeText:true, from:null,to:null, single:false, ref:null, priceType:null, sourceBucket:true, header:["valid_thru"], cols:["part","source_bucket","qty","uom","narration"], idPrefix:"DCR" },
  RC_IN_RET:         { label:"RC In (Returnable)", ledger:null, ledgerFromAllocation:true, from:null,to:null, single:false, ref:null, priceType:null, sourceBucket:true, dcAllocationVariant:true, header:["posting_date"], cols:["part","source_bucket","qty","uom","narration"], idPrefix:"RCR" },
  DC_OUT_REPLACE:    { label:"DC out (Replacement)", ledger:"Vendor JW", ledgerFreeText:true, from:null,to:null, single:false, ref:null, priceType:null, sourceBucket:true, header:["valid_thru"], cols:["part","source_bucket","qty","uom","narration"], idPrefix:"DCP" },
  RC_IN_REPLACE:     { label:"RC In (Replacement)", ledger:null, ledgerFromAllocation:true, from:null,to:null, single:false, ref:null, priceType:null, sourceBucket:true, dcAllocationVariant:true, header:["posting_date"], cols:["part","source_bucket","return_bucket","qty","uom","narration"], idPrefix:"RCP" },
  DC_OUT_NONRET:     { label:"DC Out (Non returnable)", ledger:"Vendor JW", ledgerFreeText:true, from:null,to:null, single:false, ref:null, priceType:null, sourceBucket:true, header:["valid_thru"], cols:["part","source_bucket","qty","uom","narration"], idPrefix:"DCN" },
  PRODUCTION:        { label:"Production log", ledger:null, special:"production", idPrefix:"PRD" },
};

/* Vouchers page layout: headings with child tiles (exact spec order) */
export const VOUCHER_LAYOUT = [
  { heading:"Purchase", items:["PURCHASE_ORDER","PURCHASE","DEBIT_NOTE_RC"] },
  { heading:"Delivery Challan", items:["DC_OUT_JW","RC_IN_JW"] },
  { heading:"Production", items:["PRODUCTION"] },
  { heading:"Sales", items:["SALES_ORDER","SALES_LOCAL","RESALE","CREDIT_NOTE"] },
  { heading:"QC rejection", items:["PROCESS_REJECTION","SCRAP_SALES","MATERIAL_REJECTION","DEBIT_NOTE_DN"] },
  { heading:"Delivery Challan (others)", items:["DC_OUT_RET","RC_IN_RET","DC_OUT_REPLACE","RC_IN_REPLACE","DC_OUT_NONRET"] },
];

/* date helpers — DD/MM/YYYY everywhere */
export const toDMY = (d) => { if(!d) return ""; const x=new Date(d); if(isNaN(x)) return d;
  const p=n=>String(n).padStart(2,"0"); return `${p(x.getDate())}/${p(x.getMonth()+1)}/${x.getFullYear()}`; };
export const todayISO = () => new Date().toISOString().slice(0,10);
export const money = (n) => (+n||0).toLocaleString("en-IN",{minimumFractionDigits:2,maximumFractionDigits:2});
