    # # # This source code is protected under the license referenced at
    # # # https://github.com/NRLMMD-GEOIPS.

GeoIPS CI Repository
====================

The ``sync`` directory contains files that are common between all plugin repositories,
and can be sync'ed explicitly in the given directory structure.  This includes linting
configuration files, standard GeoIPS settings (.gitignore, CHANGELOG.rst, etc), as
well as workflows to include in every repository.  The workflows in the sync directory
call the reusable workflows found in geoips_ci/.github/workflows.

The github workflows directory contains reusable workflows that are referenced in
the workflows found in the sync directory.  All plugin repositories will use these
reusable workflows for their required CI.

Currently on PR-merge and tag based workflows are included in the geoips_ci repository
(since those are unable to run via repository rulesets across the entire organization,
so there was no other way to easily port to all repositories).  Eventually we will
port all existing GitHub Actions to reusable workflows in the geoips_ci repo, allowing
external collaborators outside the GeoIPS organization to use consistent CI/CD, as
they can reference the same reusable workflows in this repository as the NRLMMD-GEOIPS
repositories.
