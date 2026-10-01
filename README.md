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

**Trusted runs** (not held): ``push``, ``workflow_dispatch``, ``schedule``, ``release``,
``merge_group``, ``repository_dispatch``, and pull requests from a branch of the same
repository. Every other event is held for approval, so a new event type fails closed.

**Limits of the gate.** For a ``pull_request`` event GitHub runs the workflow files from
the pull request's own merge commit, so a fork can edit or delete the gate in any workflow
that lives in the repository it is changing (for example ``integ_test.yaml``). The gate is
only tamper-proof for workflows a pull request cannot change: the ``ruleset-*`` workflows
in this repository when they are used as organization ruleset required workflows. For all
in-repository workflows that use a self-hosted runner, also turn on
Settings -> Actions -> General -> "Approval for running fork pull request workflows from
contributors" -> "Require approval for all external contributors" (private and internal
repositories: "Require approval for fork pull request workflows"; both can be enforced at
organization level). GitHub applies that setting before any workflow file from the fork
runs; note it does not hold forks of organization members, the gate does. GitHub recommends
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
* Approving a fork run means running its code on the self-hosted runner (as root inside
  containers, with the workspace and test data mounted). Review it as you would before
  merging. ``reusable-ci`` and the ``reusable-doc-test`` container jobs empty the workspace
  (including ``.git``) after a fork run; ``reusable-ci`` also does so before the next run if
  that cleanup did not happen.
* A denied run shows its self-hosted jobs as skipped. Require the whole workflow (as the
  organization ruleset required workflows do), not only individual job names, in branch
  protection, since GitHub counts a skipped job as passed.
* Every self-hosted job must depend on the gate and check
  ``needs.fork-gate.outputs.allowed == 'true'`` in its own ``if``. Jobs that use
  ``always()`` or ``!cancelled()`` would otherwise still run when the gate denied the run.

Self-hosted runner maintenance
------------------------------

The runner's Docker daemon is shared with other users, so cleanup only touches material
created by this CI:

* stopped containers labelled ``geoips-ci=true`` (``reusable-ci.yaml`` labels every
  container it starts, plus a per-run label), and labelled containers still running after
  ``CI_ORPHAN_HOURS`` (default 6), which a cancelled job left behind,
* images whose tags are all CI tags (``geoips:dev-<commit sha>-<run>-<attempt>``,
  ``geoips:cache``), aged from their last tag time; an image with any other tag is kept,
* with ``PRUNE_DANGLING_GEOIPS_IMAGES=true``, dangling copies of the GeoIPS image identified
  by their registry digest from ``ghcr.io/nrlmmd-geoips/geoips`` (set ``CI_IMAGE_REPO`` to
  change it). Off by default because Docker cannot tell who pulled them,
* with ``CLEAN_STALE_TESTDATA=true``, test data directories not modified for 30 days.

Images are deliberately not labelled: image labels are published with the image and
inherited by every container created from it, so other users' GeoIPS containers would
match. Images still used by a container are never removed, and nothing in ``/tmp`` is
deleted. ``docker system prune`` and ``docker builder prune`` are never run.

* ``reusable-ci.yaml`` removes its own image and any containers of the run at the end of
  every run. When one of its builds, pulls or tag moves leaves an image untagged (the
  previous ``geoips:cache``, base image or ``latest``), it removes that image right away
  unless a container uses it.
* ``scheduled-runner-prune.yaml`` runs ``scripts/runner-prune.sh`` nightly and weekly
  (manual runs default to ``--dry-run``). The runner must be available to ``geoips_ci``,
  and the job prunes only the host whose runner picks it up; GitHub also disables schedules
  in public repositories after 60 days without activity. With several runner hosts, or to
  avoid both limits, run the script from cron or a systemd timer on each host:
  ``scripts/runner-prune.sh --nightly|--weekly [--dry-run]``.
* ``scripts/test-runner-prune.sh`` checks the script's safety rules against a fake
  ``docker`` (run it after any change; ``check-ci-scripts.yaml`` runs it with
  ``shellcheck`` on every pull request, and also fails if a reusable workflow reference does
  not point at ``@main``).
* Test data defaults to ``~/.geoips-testdata`` (before: ``/tmp/geoips_outdirs``). Set the
  ``TESTDATA_PATH`` variable to put it on a large data volume. The old ``/tmp`` directory is
  not deleted automatically, since another repository may still use it; CI warns while it
  exists. Delete it once no CI uses it.
* The ``deps`` image is built with inline cache metadata and the copy pushed to
  ``ghcr.io/nrlmmd-geoips/geoips:build-cache-<arch>`` is used directly as a cache source, so
  BuildKit fetches only the layers it reuses instead of pulling the whole image every run.
* BuildKit build cache is not pruned, Docker cannot limit that to one project. If it grows
  too large, give the CI its own ``docker buildx`` builder and prune only that builder.
