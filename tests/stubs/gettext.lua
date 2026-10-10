-- Test stub for KOReader's gettext.
return setmetatable({ pgettext = function(_, s) return s end, ngettext = function(s, p, n) return n == 1 and s or p end },
    { __call = function(_, s) return s end })
