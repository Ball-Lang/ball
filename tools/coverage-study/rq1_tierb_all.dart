/// Tier B of the third-party coverage study (issue #493) — **whole-package**
/// behavioural substitution.
///
/// The per-file harness (`rq1_tierb.dart`) answers "can this ONE file survive
/// the round trip?" — every other file in the checkout stays original, so a
/// construct that only breaks in combination with another substituted file is
/// invisible to it. This mode answers the stricter question: substitute every
/// eligible file of a package AT ONCE, with no restore in between, and run the
/// package's own `dart test` a single time. One verdict per package.
///
/// The two numbers are meant to be read together. #488's own ad-hoc prototype
/// measured 88 of 106 files clean per-file but only 1 of 5 packages clean
/// whole-package: a pipeline can be 83% right per file and still not produce a
/// working library, because "clean" compounds multiplicatively across a package.
///
/// Everything else — the taxonomy, the baseline rule, the per-run timeout, the
/// digest-verified restoration and the positive floor — is shared with the
/// per-file harness; see `rq1_tierb.dart` for the rationale behind each.
///
/// Usage (from the repo root):
///
///   dart run tools/coverage-study/rq1_tierb_all.dart \
///       --pins tools/coverage-study/packages/dart.json \
///       --checkouts <dir-with-one-clone-per-package> \
///       [--json <report.json>] [--jobs 2] [--test-timeout 600]
///
///   dart run tools/coverage-study/rq1_tierb_all.dart \
///       --package <name> --checkout <package-root>
library;

import 'rq1_tierb.dart';

Future<void> main(List<String> args) => runTierB(
  args,
  tierLabel: 'Tier B (whole-package)',
  study: (package, checkout, options) =>
      studyPackageWhole(package, checkout, options: options),
);
