(() => {
  "use strict";

  // Keep this iPhone variant catalog aligned with get_esim_stock_v1.
  // https://support.apple.com/en-us/108044
  // https://support.apple.com/en-us/118569
  const variants = [
    ["14", ["A2649"], ["A2881", "A2882", "A2883", "A2884"], "us_only"],
    ["14plus", ["A2632"], ["A2885", "A2886", "A2887", "A2888"], "us_only"],
    ["14pro", ["A2650"], ["A2889", "A2890", "A2891", "A2892"], "us_only"],
    ["14promax", ["A2651"], ["A2893", "A2894", "A2895", "A2896"], "us_only"],
    ["15", ["A2846"], ["A3089", "A3090", "A3092"], "us_only"],
    ["15plus", ["A2847"], ["A3093", "A3094", "A3096"], "us_only"],
    ["15pro", ["A2848"], ["A3101", "A3102", "A3104"], "us_only"],
    ["15promax", ["A2849"], ["A3105", "A3106", "A3108"], "us_only"],
    ["16", ["A3081"], ["A3286", "A3287", "A3288"], "us_only"],
    ["16plus", ["A3082"], ["A3289", "A3290", "A3291"], "us_only"],
    ["16pro", ["A3083"], ["A3292", "A3293", "A3294"], "us_only"],
    ["16promax", ["A3084"], ["A3295", "A3296", "A3297"], "us_only"],
    ["16e", ["A3212"], ["A3408", "A3409", "A3410"], "us_only"],
    ["17", ["A3258", "A3519"], ["A3520", "A3521"], "multi_region"],
    ["17pro", ["A3256", "A3522"], ["A3523", "A3524"], "multi_region"],
    ["17promax", ["A3257", "A3525"], ["A3526", "A3527"], "multi_region"],
    ["17e", ["A3575"], ["A3634", "A3635"], "multi_region"],
    ["air", ["A3260", "A3516", "A3517", "A3518"], [], "all"],
    ["18pro", ["A3472", "A3713"], ["A3714", "A3715"], "multi_region"],
    ["18promax", ["A3473", "A3716"], ["A3717", "A3718"], "multi_region"]
  ];
  const usRegions = new Set(["united states", "usa", "us", "puerto rico"]);
  const multiRegionCodes = new Set(["C/A", "VC/A", "CL/A", "J/A"]);
  const multiRegions = new Set([
    "canada", "japan", "mexico", "guam", "united arab emirates", "uae",
    "saudi arabia", "bahrain", "kuwait", "oman", "qatar", "u.s. virgin islands"
  ]);

  window.GREENLOOP_ESIM_ONLY_EVIDENCE = device => {
    if (String(device?.brand ?? "").toLowerCase() !== "apple" && device?.device_platform !== "ios") return null;
    const model = String(device.model ?? "");
    const region = String(device.region ?? device.specification_region ?? "").trim().toLowerCase();
    const modelNumber = model.match(/\bA[0-9]{4}\b/i)?.[0].toUpperCase();
    const regionNumber = region.match(/\bA[0-9]{4}\b/i)?.[0].toUpperCase();
    if (modelNumber && regionNumber && modelNumber !== regionNumber) return null;
    const aNumber = modelNumber || regionNumber;
    const modelKey = model.replace(/\bA[0-9]{4}\b/gi, "").replace(/^\s*iphone/i, "")
      .replace(/[^a-z0-9]+/gi, "").toLowerCase();
    const direct = aNumber && variants.find(([, esim, physical]) => esim.includes(aNumber) || physical.includes(aNumber));
    if (direct) return (!modelKey || modelKey === direct[0]) && direct[1].includes(aNumber) ? "a_number" : null;
    const rule = variants.find(([key]) => key === modelKey)?.[3];
    if (rule === "all") return "model";
    if (aNumber || !rule) return null;
    const salesCode = region.match(/\b[A-Z]{1,3}\/A\b/i)?.[0].toUpperCase();
    if (salesCode === "LL/A" || usRegions.has(region)) return "sales_region";
    if (rule === "multi_region" && (multiRegionCodes.has(salesCode) || multiRegions.has(region))) return "sales_region";
    return null;
  };
})();
