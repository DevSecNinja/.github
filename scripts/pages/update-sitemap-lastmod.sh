#!/usr/bin/env bash
#
# Sets every sitemap <lastmod> date to today (job deploy of
# .github/workflows/pages.yml, when update-sitemap-lastmod is true).

set -euo pipefail
today="$(date -u +%Y-%m-%d)"
if [ ! -f "${SITEMAP_PATH}" ]; then
    echo "::error::Sitemap file '${SITEMAP_PATH}' does not exist."
    exit 1
fi
if ! grep -Eq "<lastmod>[0-9]{4}-[0-9]{2}-[0-9]{2}</lastmod>" "${SITEMAP_PATH}"; then
    echo "::error::No sitemap lastmod tags found in '${SITEMAP_PATH}'."
    exit 1
fi
sed -i -E \
    "s|<lastmod>[0-9]{4}-[0-9]{2}-[0-9]{2}</lastmod>|<lastmod>${today}</lastmod>|g" \
    "${SITEMAP_PATH}"
