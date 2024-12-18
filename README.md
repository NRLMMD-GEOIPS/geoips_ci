    # # # This source code is protected under the license referenced at
    # # # https://github.com/NRLMMD-GEOIPS.

GeoIPS CI Repository
====================

The ``sync`` directory contains files that are common between all plugin repositories,
and can be sync'ed explicitly in the given directory structure.  This includes linting
configuration files, standard GeoIPS settings (.gitignore, CHANGELOG.rst, etc), as
well as workflows to include in every repository.  The workflows in the sync directory
call the reusable workflows found in geoips_ci/.github/workflows. All plugin repositories
will use these workflows for their required CI.

Eventually we will likely set up automated workflows to sync these files, but for now they
are manually synced to GeoIPS plugin repositories using a command like:

```
cp -rp $GEOIPS_PACKAGES_DIR/geoips_ci/sync/. $GEOIPS_PACKAGES_DIR/geoips/
```

Current status of GitHub CI
---------------------------

GitHub CI setup seems to be a moving target.  This is the current set of interesting
realizations (current as of 11 December 2024)

A few notes on GitHub PR status checks:
1. Locally defined workflows WILL NOT prevent PR merge, MUST use organization repository
   rulesets required workflows for PR status checks to be required.
   (lint, doc-test, proper-release-note-edits)
2. Organization wide required workflows MUST live in the .github directory of a repository
   within the organization - you CAN NOT point to a workflow in a random directory from
   the organization repository rulesets.
3. We are going to Store the organization wide PR status check workflows in
   geoips_ci/.github/workflows (ruleset-lint, ruleset-doc-test,
   ruleset-proper-release-note-edits), and use these from the repository rulesets
   as the required workflows. We will NOT sync these workflows to every repository across
   the organization.
5. External collaborators can still use these workflows - they are stored in the
   "sync_external" folder in the geoips_ci repo (since we do not need to sync these
   workflows to every repository within the organization, since they are called via
   the repository rulesets). External users can sync both the "sync" and "sync_external"
   directories in geoips_ci repo to have the complete GeoIPS setup.
