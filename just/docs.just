# Documentation site (mdBook). docs-site/ + README.org -> docs-site/book/.
# Needs `mdbook` and `pandoc` on PATH; scripts/docs-build.sh says so if not.
# CI (.github/workflows/docs.yml) calls `just docs-build`, so any other CI can too.

# Build the site into docs-site/book/
docs-build:
    bash scripts/docs-build.sh build

# Build, serve on localhost:3000 and open a browser
docs-serve:
    bash scripts/docs-build.sh serve

# Delete generated pages and the built site
docs-clean:
    rm -rf docs-site/src/generated docs-site/book
