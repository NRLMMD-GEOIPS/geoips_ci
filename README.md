    # # # This source code is subject to the license referenced at
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
6. geoips_ci repo must be internal or public, not private, in order to use reusable workflows
   or repository rulesets from internal repos.
7. geoips_ci repo must have permissions granted on Settings -> Actions -> General -> Access
   for other repos to use its rulesets and workflows

Pull requests from forks
------------------------

Code from a fork should not run on the self-hosted runner unreviewed. Every reusable
workflow that uses the self-hosted runner for pull request code (``reusable-ci``,
``reusable-lint``, ``reusable-doc-test``, ``reusable-proper-release-note-edits``) first
calls ``reusable-fork-gate``. For a pull request from a fork, the gate waits on a GitHub
Environment with required reviewers, and every self-hosted job is skipped unless a
reviewer approves. Pull requests from branches of the repository itself are not held.

**Limits of the gate.** For a ``pull_request`` event GitHub runs the workflow files from
the pull request's own merge commit, so a fork can edit or delete the gate in any workflow
that lives in the repository it is changing (for example ``integ_test.yaml``). The gate is
only tamper-proof for workflows a pull request cannot change: the ``ruleset-*`` workflows
in this repository when they are used as organization ruleset required workflows. For all
in-repository workflows that use a self-hosted runner, also turn on
Settings -> Actions -> General -> "Fork pull request workflows" ->
"Require approval for all outside collaborators" (can be enforced at organization level).
GitHub applies that setting before any workflow file from the fork runs. GitHub recommends
against attaching self-hosted runners to public repositories at all.

One-time setup in EACH repository that runs these workflows (Settings -> Environments):

1. Create an environment named ``fork-approval`` (or pass another name with the
   ``fork_approval_environment`` input).
2. Add an organization team as "Required reviewers".
3. Do not restrict deployment branches, fork pull requests run on ``refs/pull/*/merge``.

Without required reviewers, GitHub creates the environment with no protection and fork
pull requests are NOT held for approval.

Things to know:

* Each workflow run needs its own approval (CI, lint, doc-test and release-note checks are
  separate runs), and a new push to the pull request needs approval again.
* Fork pull requests get no secrets and a read-only token, so approved fork runs do not
  push images or caches. For fork pull requests of ``geoips`` the doc-test jobs use the
  ``doclinttest-latest`` image, as plugin repositories do.
* Every self-hosted job must depend on the gate and check
  ``needs.fork-gate.outputs.allowed == 'true'`` in its own ``if``. Jobs that use
  ``always()`` or ``!cancelled()`` would otherwise still run when the gate denied the run.

Self-hosted runner maintenance
------------------------------

The runner's Docker daemon is shared with other users, so cleanup only touches material
created by this CI: containers and images labelled ``geoips-ci=true``, older unlabelled
``geoips:dev-*``/``geoips:cache`` images whose only tag is ours, superseded dangling copies
of the GeoIPS base image pulled from ``ghcr.io/nrlmmd-geoips/geoips`` (identified by their
registry digest, set ``CI_IMAGE_REPO`` to change it), stale ``test_data_*`` directories, and
``geoips*``/``pytest-of-*`` leftovers in ``/tmp``. Images still used by a
container are never removed. It never runs ``docker system prune`` or
``docker builder prune``.

* ``reusable-ci.yaml`` removes its own image at the end of every run.
* ``scheduled-runner-prune.yaml`` runs ``scripts/runner-prune.sh`` nightly and weekly
  (manual runs default to ``--dry-run``). The script can also be run from host cron or a
  systemd timer: ``scripts/runner-prune.sh --nightly|--weekly [--dry-run]``.
* Test data defaults to ``~/.geoips-testdata``; set the ``TESTDATA_PATH`` variable to
  choose another location. ``CLEAN_STALE_TESTDATA=false`` disables removal of test data
  older than 30 days.
* BuildKit build cache is not pruned, Docker cannot limit that to one project. If it grows
  too large, give the CI its own ``docker buildx`` builder and prune only that builder.
