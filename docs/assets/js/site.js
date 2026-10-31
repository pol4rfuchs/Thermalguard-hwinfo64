(() => {
  const yearNodes = document.querySelectorAll('[data-year]');
  yearNodes.forEach((node) => { node.textContent = new Date().getFullYear(); });

  const buildNodes = document.querySelectorAll('[data-build-date]');
  buildNodes.forEach((node) => {
    node.textContent = new Date().toISOString().slice(0, 10);
  });

  const search = document.querySelector('[data-site-search]');
  if (!search) return;

  const cards = Array.from(document.querySelectorAll('[data-search-card]'));
  const groups = Array.from(document.querySelectorAll('[data-cat-group]'));
  search.addEventListener('input', () => {
    const needle = search.value.trim().toLowerCase();
    cards.forEach((card) => {
      const haystack = card.textContent.toLowerCase();
      card.hidden = needle.length > 0 && !haystack.includes(needle);
    });
    // Hide category headings whose cards are all filtered out.
    groups.forEach((group) => {
      group.hidden = !group.querySelector('[data-search-card]:not([hidden])');
    });
    // Keep the docs-theme sidebar in sync with the filter.
    document.querySelectorAll('[data-side-link]').forEach((link) => {
      const card = cards.find((c) => c.getAttribute('href') === link.getAttribute('href'));
      link.hidden = !!card && card.hidden;
    });
  });
})();
