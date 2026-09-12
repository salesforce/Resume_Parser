# Contributing Guide For Résumé Parser

This page lists the operational governance model of this project, as well as the recommendations and requirements for how to best contribute to Résumé Parser. We strive to obey these as best as possible. As always, thanks for contributing – we hope these guidelines make it easier and shed some light on our approach and processes.

# Governance Model

## Salesforce Sponsored

The intent and goal of open sourcing this project is to increase the contributor and user base. However, only Salesforce employees will be given `admin` rights and will be the final arbiters of what contributions are accepted or not.

# Getting Started

This project is a Salesforce DX unlocked package that delivers an in-chat Agentforce résumé wizard: a next-gen (Agent Builder 2.0 / Agent Script) employee agent renders a custom Lightning type wizard that uploads a résumé, parses it with a GenAI vision prompt template, lets the user review/edit, and saves structured `Work_Experience__c` records under a `Resume_Data__c` record linked to a Contact. See the [README](README.md) for installation and usage details.

# Issues, Requests & Ideas

Use the GitHub [Issues](https://github.com/salesforce/Resume_Parser/issues) page to submit issues, enhancement requests, and discuss ideas.

### Bug Reports and Fixes

- If you find a bug, please search for it in the Issues, and if it isn't already tracked, create a new issue. Even if an Issue is closed, feel free to comment and add details — it will still be reviewed.
- Issues that have already been identified as a bug (note: able to reproduce) will be labelled `bug`.
- If you'd like to submit a fix for a bug, send a Pull Request and mention the Issue number.
  - Include tests that isolate the bug and verify that it was fixed.

### New Features

- If you'd like to add a new feature to the project, describe the need in an Issue first so we can discuss design and scope.
- Provide tests and documentation whenever possible — for Apex, keep meaningful unit-test coverage so the package continues to build code-coverage-validated versions.

# Contribution Checklist

- [ ] Clean, modular, testable code with appropriate Apex test coverage.
- [ ] `sf agent validate authoring-bundle` passes for any `.agent` change.
- [ ] The package still builds: `sf package version create --definition-file config/project-scratch-def.json --code-coverage`.
- [ ] No customer-identifying data, credentials, or org IDs in committed files.

# Creating a Pull Request

1. Fork or branch, commit your changes with clear messages.
2. Ensure the package builds and any Apex tests pass.
3. Open a Pull Request describing the change and linking the related Issue.

# Contributor License Agreement (CLA)

To accept your pull request, Salesforce requires you to submit a CLA. You only need to do this once
to contribute to any Salesforce open-source project.

Complete your CLA here: <https://cla.salesforce.com/sign-cla>

# Code of Conduct

Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).

# License

By contributing your code, you agree to license your contribution under the terms of the
[LICENSE](LICENSE.txt) (Apache License 2.0) and to sign the
[Salesforce CLA](https://cla.salesforce.com/sign-cla).
