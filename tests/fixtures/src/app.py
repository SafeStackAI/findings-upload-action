"""Fixture source used by the staging smoke test's semgrep scan."""


def run_untrusted(user_input: str) -> object:
    # Deliberately unsafe: this fixture exists only so the staging smoke
    # test's semgrep scan has something to find. It is never executed.
    return eval(user_input)  # noqa: S307
