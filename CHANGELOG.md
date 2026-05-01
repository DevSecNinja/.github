# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0](https://github.com/DevSecNinja/.github/compare/v1.1.0...v1.2.0) (2026-05-01)


### Features

* **actions:** add notify-irm composite action ([#51](https://github.com/DevSecNinja/.github/issues/51)) ([a877d35](https://github.com/DevSecNinja/.github/commit/a877d35266a54e54ef043e60a290ed76b4d7b34e))
* **labels:** rename automerge to `merge: auto` and add release-please labels ([#45](https://github.com/DevSecNinja/.github/issues/45)) ([fa92001](https://github.com/DevSecNinja/.github/commit/fa92001d3877b58e3c8f8b0fa2f6f9230fbb0792))
* **mise:** update tool zizmor ( 1.23.1 ➔ 1.24.1 ) ([9e3203f](https://github.com/DevSecNinja/.github/commit/9e3203f70c12fe4b918fa0cd26238b553964a413))
* **mise:** update tool zizmor ( 1.23.1 ➔ 1.24.1 ) ([#39](https://github.com/DevSecNinja/.github/issues/39)) ([e3291b1](https://github.com/DevSecNinja/.github/commit/e3291b1e914c6930a726cbcdc56ccab4fcbdb61a))
* **open-pr:** add composite action to open or update PRs from working tree ([#49](https://github.com/DevSecNinja/.github/issues/49)) ([6764c0f](https://github.com/DevSecNinja/.github/commit/6764c0fb5ffc25207571b159dc255c8f77922c62))
* **renovate:** add `merge: manual` label rules ([#46](https://github.com/DevSecNinja/.github/issues/46)) ([f447e9e](https://github.com/DevSecNinja/.github/commit/f447e9eeefdcfc24fba0b4b600be4c321fa8f208))

## [1.1.0](https://github.com/DevSecNinja/.github/compare/v1.0.0...v1.1.0) (2026-05-01)


### Features

* add custom manager for Ansible inventory YAML files ([46eb1be](https://github.com/DevSecNinja/.github/commit/46eb1be9eba6a1e16b068f956880bedfe3900431))
* add host rules and registry aliases for dhi.io ([641aa02](https://github.com/DevSecNinja/.github/commit/641aa0204e8cddbad9b515b6954221309307d841))
* add labels and vulnerability alerts to Renovate configuration ([b9273f0](https://github.com/DevSecNinja/.github/commit/b9273f0e9f610757c8c6a0971218f1c0a7cc8d98))
* **config-sync:** ensure label exists before opening a PR ([1cc371b](https://github.com/DevSecNinja/.github/commit/1cc371b697c812683b878d0e2201bb1f65718424))
* **labeler:** add issue labeling via github/issue-labeler ([794bec0](https://github.com/DevSecNinja/.github/commit/794bec023309821156952f39b2ab000f5a438ce3))
* **lint:** add auto-fix mode reusable workflow and template ([f163ca1](https://github.com/DevSecNinja/.github/commit/f163ca18a0a8644c916c8a034f39335f848de491))
* **lint:** add shellcheck/shfmt exclude inputs ([17aa697](https://github.com/DevSecNinja/.github/commit/17aa6976bea066f1834c052e8da01fa19962ebfe))
* **lint:** add shellcheck/shfmt exclude inputs to reusable lint workflow ([0c4551a](https://github.com/DevSecNinja/.github/commit/0c4551a1ebe5f5332511514e4d45a9bb4df2df09))
* **mise:** update tool dprint ( 0.53.2 ➔ 0.54.0 ) ([963e1d1](https://github.com/DevSecNinja/.github/commit/963e1d1bdc261be68c68a632fe3f4dac84df43ae))
* **release-please:** wire GitHub App token + onboarding doc ([217074e](https://github.com/DevSecNinja/.github/commit/217074ec255c5d73af534576479c34844667a2d1))
* **release-please:** wire GitHub App token + onboarding doc ([e29c6a9](https://github.com/DevSecNinja/.github/commit/e29c6a934b4210dd13f909d5c5745914f584f020))
* **release:** add release-please reusable workflow ([4890fa8](https://github.com/DevSecNinja/.github/commit/4890fa871a85bacb5a6f25e56415849d33652712))
* **release:** add release-please reusable workflow ([7ed381a](https://github.com/DevSecNinja/.github/commit/7ed381a72cf3d86d34aa5db3818dd468968e46ce))
* **release:** add release-publish composite action ([ee0804b](https://github.com/DevSecNinja/.github/commit/ee0804b737700aeecd6d1b1bc85ab57107c880e3))
* **release:** add release-publish composite action ([1f5bcf2](https://github.com/DevSecNinja/.github/commit/1f5bcf20495c36c07f1040a4f79a8053a4649cdb))
* **release:** onboard .github repo to release-please ([7d8ca17](https://github.com/DevSecNinja/.github/commit/7d8ca17e0611196f47e35113f25754e0d73e7994))
* **release:** onboard .github repo to release-please ([0e0be6d](https://github.com/DevSecNinja/.github/commit/0e0be6da7f1bf0e0e331792e181417a55349e16d))
* **renovate:** add custom manager for dotfiles log.sh release pin ([aab92ba](https://github.com/DevSecNinja/.github/commit/aab92ba8d190f80d2dce8393c37b3394ee078fb3))
* **renovate:** expand auto-merge to all minor/patch updates ([78be78d](https://github.com/DevSecNinja/.github/commit/78be78dd79bc07729a7daa0bddd91ecf90c006a7))
* **todo-to-issue:** add auto_assign and label inputs, fix todo-to-issue label ([f830665](https://github.com/DevSecNinja/.github/commit/f830665929b67060bac3a65d4cfc4dde3f81a82f))
* update Renovate configuration to extend best practices and remove deprecated settings ([632d58e](https://github.com/DevSecNinja/.github/commit/632d58e4ec6b8b0d618b871d823c6f970f6bfc15))
* **workflow-templates:** pin all template refs to v1.0.0 and add changelog category ([8b63cf9](https://github.com/DevSecNinja/.github/commit/8b63cf9fda6a2ea132593ff03755d90234a250ca))


### Bug Fixes

* **checkov:** filter skipped checks from SARIF before upload ([36b12c2](https://github.com/DevSecNinja/.github/commit/36b12c20b17e9ae1d596524928fae013cd9a4cbb))
* **config-sync:** replace stash with force-checkout and restore from tmp ([26b001e](https://github.com/DevSecNinja/.github/commit/26b001eb16d0f67887e26dfab340573a6398efce))
* **config-sync:** stash untracked files before branch checkout and auto-create label ([b9b199e](https://github.com/DevSecNinja/.github/commit/b9b199e6ef225c6e8da6ded4da2cf2c492f6d94e))
* **github-release:** update release jdx/mise ( v2026.4.5 ➔ v2026.4.9 ) ([bb51292](https://github.com/DevSecNinja/.github/commit/bb51292e9a07d5e6d1a512047949bf07028388e1))
* **mise:** update tool pipx:checkov ( 3.2.513 ➔ 3.2.521 ) ([48fd48b](https://github.com/DevSecNinja/.github/commit/48fd48b1d523ecd73bf1fa99a5d4dfcbb5b1b115))
* **mise:** update tool shfmt ( 3.13.0 ➔ 3.13.1 ) ([f268d08](https://github.com/DevSecNinja/.github/commit/f268d0881372f838b16d32c3f92a14665237bbac))
* **renovate:** auto-merge github-actions pinDigest updates ([5979dc3](https://github.com/DevSecNinja/.github/commit/5979dc3c548db482fd2fa730c312bec33caa6f00))
* **workflow-templates:** update event types format in assign-issue-to-codeowners.yml ([edb5985](https://github.com/DevSecNinja/.github/commit/edb5985189b734443c2948205d52939cdc24a6e9))
* **workflows:** quote IDENTIFIERS expression in todo-to-issue workflow ([27869fe](https://github.com/DevSecNinja/.github/commit/27869febccdd16c256414c265650ec3ba0aba04e))

## [1.0.0] - 2026-04-21

### Bug Fixes

- Update devcontainer image to use the latest version from DevSecNinja ([`3690eec`](https://github.com/DevSecNinja/.github/commit/3690eecaef2987ec2c78be17243d21178fab299f))
- Include issue title in assignment log for CODEOWNERS workflow ([`67c91ca`](https://github.com/DevSecNinja/.github/commit/67c91ca89bb02fcd8cb0be748f85bef6625cd6a8))
- Set default issue number to 0 in CODEOWNERS assignment workflow ([`864019e`](https://github.com/DevSecNinja/.github/commit/864019e0a1f7c40f34c139a810075077edbc0570))
- Set default value for issue number input in CODEOWNERS workflow ([`dd2a9be`](https://github.com/DevSecNinja/.github/commit/dd2a9be318e8d99d5af46009ed75dbdf3c554721))
- Update workflow reference for issue assignment ([`e6ad720`](https://github.com/DevSecNinja/.github/commit/e6ad720e4a00a5b1563d0f20e9c08435389146f6))
- Validate issue number input for manual assignment in CODEOWNERS workflow ([`07093eb`](https://github.com/DevSecNinja/.github/commit/07093eb3b8525e0b6dc8165a1e3230e4ccd4bccc))
- Update workflow reference to main commit ([`39481d1`](https://github.com/DevSecNinja/.github/commit/39481d121b64ed09c8e44d291c2948510262bcd2))
- Refactor workflow template properties to use JSON format for consistency ([`23f2f2a`](https://github.com/DevSecNinja/.github/commit/23f2f2a58297fbad9de8b8eed84217e99ba9f4f1))
- **github-release**: Update release jdx/mise ( v2026.4.3 ➔ v2026.4.5 ) ([`0a26e00`](https://github.com/DevSecNinja/.github/commit/0a26e0036ff47b1c45108a583f26aa71a6c033cf))
- **renovate**: Match mise-version input in workflows custom manager ([`9dec6d6`](https://github.com/DevSecNinja/.github/commit/9dec6d696e89ea3f56a5afa505d6a0365cd736b3))
- Remove filter_commits in cog.toml ([`ce60b28`](https://github.com/DevSecNinja/.github/commit/ce60b28bdc291c58ab62ce2838f85a1fe3a955bb))
- Ignore 'Initial commit' in cliff.toml and cog.toml templates ([`c6aae32`](https://github.com/DevSecNinja/.github/commit/c6aae32bab483af61d6622da87aca9e69c8cfcb3))
- Rename README.md to profile/README.md ([`8f8e434`](https://github.com/DevSecNinja/.github/commit/8f8e43411d66cf781fcb53de0ee39ccea6a4971c))

### CI/CD

- **github-action**: Pin action actions/github-script to 3a2844b ([`7480cde`](https://github.com/DevSecNinja/.github/commit/7480cded15399153cefdcf4d9203379cd7cd2f93))
- **github-action**: Update action github/codeql-action ( v4.35.1 ➔ v4.35.2 ) ([`ad09cc2`](https://github.com/DevSecNinja/.github/commit/ad09cc2a8d88afc7e653d53bcd895c02a5b39d9b))
- **github-action**: Pin action devsecninja/.github to 195660c ([`2a12818`](https://github.com/DevSecNinja/.github/commit/2a12818f2dcaaef0b366ce42911bbb49b0d4576d))

### Documentation

- Add ADR requiring caller-owned versions for reusable workflows ([`ca4dc5a`](https://github.com/DevSecNinja/.github/commit/ca4dc5aca0d606951f6ae6d0424c750458294724))

### Features

- Add guide for writing Conventional Commit messages and release process ([`78e85e5`](https://github.com/DevSecNinja/.github/commit/78e85e5c91dd19a51ffba3e912aa928f412c1c21))
- Add issue number input for manual assignment in CODEOWNERS workflow ([`d70256f`](https://github.com/DevSecNinja/.github/commit/d70256f00b8cd2fabca5d80abe0621e010111eb6))
- Add reusable workflow for auto-assigning issues to CODEOWNERS ([`2978f7f`](https://github.com/DevSecNinja/.github/commit/2978f7f87d39870cb8193069a2f1f01d55dfc6ea))
- Add basic devcontainer configuration ([`82da39f`](https://github.com/DevSecNinja/.github/commit/82da39ff9a11d2f48caa9295d85e6cf30c438900))
- Add label-sync caller workflow for .github repo itself ([`a5d8515`](https://github.com/DevSecNinja/.github/commit/a5d8515325b15f5a5c744b2b1de92f4526b77650))
- Add vulnerabilityAlerts and lockFileMaintenance to base config ([`34679b0`](https://github.com/DevSecNinja/.github/commit/34679b04bb28aad4310d7d9138201015692ca281))
- Add assigneesFromCodeOwners and reviewersFromCodeOwners to base config ([`c799d8d`](https://github.com/DevSecNinja/.github/commit/c799d8dcb94f35c63e8f60ac12c91cdf24aa80a9))
- Add renovate.json5 to config-sync files and devcontainer template ([`5f5d5e6`](https://github.com/DevSecNinja/.github/commit/5f5d5e62490152525df9a5b979da2cb50a07ce87))
- Add cliff.toml, cog.toml, and .gitignore to config-sync templates ([`0b71da2`](https://github.com/DevSecNinja/.github/commit/0b71da279304b018d564fe36a359bfef08110451))
- Add sync-templates support to config-sync and workflow templates ([`e744bc0`](https://github.com/DevSecNinja/.github/commit/e744bc05bb096d6356cc913900ff62482e656046))
- Add pull-based config-sync workflow and config-drift lint check ([`57ab8ec`](https://github.com/DevSecNinja/.github/commit/57ab8ec508bdf5f3e5f17f22b6ee154137ee42ac))
- Add org-level GitHub defaults and base labels ([`e665ddd`](https://github.com/DevSecNinja/.github/commit/e665dddd3ae923443196ecbb322a8fd938b7bfb9))
- Add config-sync files, templates, and sync workflow ([`8beef0b`](https://github.com/DevSecNinja/.github/commit/8beef0b783bc25681ce3b87d2eb04cbcf5eabb6c))
- Add reusable lint and utility workflows ([`642f2ff`](https://github.com/DevSecNinja/.github/commit/642f2ff1c398d036f0f93338aaf429a98551057d))
- Add support for gomod in Renovate configuration ([`913b2a6`](https://github.com/DevSecNinja/.github/commit/913b2a66c537fde1783c1b245c41c581184651c2))
- Add Renovate base config ([`6ba8f69`](https://github.com/DevSecNinja/.github/commit/6ba8f698b1525c7c934f0e5471735ebfd92e9926))
- Include Renovate configs ([`95fb09c`](https://github.com/DevSecNinja/.github/commit/95fb09c4295dd957205b9c9cdae79968c2655561))
- Revise README to include personal and professional details ([`49aba34`](https://github.com/DevSecNinja/.github/commit/49aba34aefe5a38a617f4838016ae2ba2c8df9fc))

### Miscellaneous

- Add dprint config for changelog formatting ([`ba7a40c`](https://github.com/DevSecNinja/.github/commit/ba7a40c1f37c996b7c9de09d51ea795c719c3624))
- Add mise, cog, and git-cliff config for releases ([`84a6f06`](https://github.com/DevSecNinja/.github/commit/84a6f06c6e3de939e7b95bff58c0af85a84fddd4))
- Standardize to central Renovate config ([`195660c`](https://github.com/DevSecNinja/.github/commit/195660c2cde322b4f9402a20be4b2dac2fef77e0))
- Remove .gitignore from config-sync templates ([`bfd54a0`](https://github.com/DevSecNinja/.github/commit/bfd54a05facff426e416622da1e786e6fe998dc0))
- Remove lint-zizmor.yml (consolidated into lint.yml) ([`9d70999`](https://github.com/DevSecNinja/.github/commit/9d70999b12a121517fcc40c0e3839479b9bd7b49))
- Remove lint-trivy-fs.yml (consolidated into lint.yml) ([`b4d416a`](https://github.com/DevSecNinja/.github/commit/b4d416a1f145368b2b3778cf5d6b5638daf9df0f))
- Remove lint-checkov.yml (consolidated into lint.yml) ([`5b34118`](https://github.com/DevSecNinja/.github/commit/5b341185275663d5f3eb36cf129adcdc8fb7f827))
- Remove lint-shfmt.yml (consolidated into lint.yml) ([`790c99e`](https://github.com/DevSecNinja/.github/commit/790c99e257d97e0944d5bc8587290b7c37de4180))
- Remove sync.yml config (no longer using repo-file-sync-action) ([`eb5f870`](https://github.com/DevSecNinja/.github/commit/eb5f87019dcb7ae68c1a6cea6b7756e974b669d0))
- Remove config-sync workflow (BetaHuhn/repo-file-sync-action is unmaintained) ([`43c932c`](https://github.com/DevSecNinja/.github/commit/43c932c734cd240b4012b851a6b33a38f96c9655))
- Remove lint-shellcheck.yml (consolidated into lint.yml) ([`b2b4a87`](https://github.com/DevSecNinja/.github/commit/b2b4a8770a131adbfa93e17e35217195f3ede7fa))
- Remove lint-gitleaks.yml (consolidated into lint.yml) ([`86e0fac`](https://github.com/DevSecNinja/.github/commit/86e0facf4784e18c768ddc5cf5238083d6cff419))
- Remove lint-actionlint.yml (consolidated into lint.yml) ([`c2e91f7`](https://github.com/DevSecNinja/.github/commit/c2e91f7b12eda40a2575cae54549ba3ac40170bf))
- Remove lint-yamllint.yml (consolidated into lint.yml) ([`d671d36`](https://github.com/DevSecNinja/.github/commit/d671d3605677bc489f27dc62422f671e3ca9a6e6))
- Remove lint-yamlfmt.yml (consolidated into lint.yml) ([`ff22335`](https://github.com/DevSecNinja/.github/commit/ff22335d9809d42eca2565dfe82f1e8d06c8a8f8))
- Remove lint-dprint.yml (consolidated into lint.yml) ([`a7e0d3a`](https://github.com/DevSecNinja/.github/commit/a7e0d3a7c65e367d9659fedc9591a0aa50a436b7))

### Refactoring

- Consolidate 10 lint workflows into single reusable workflow ([`1746a42`](https://github.com/DevSecNinja/.github/commit/1746a429e5aa102dc7a69eb4da1cc4af21b557f7))
