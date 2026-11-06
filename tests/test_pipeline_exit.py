"""Guest pipeline termination must remain contained in the native sandbox."""

import subprocess
import sys

import pytest

_SCRIPT = '''
import asyncio
import sys
from unix_sandbox import Sandbox

async def main() -> None:
    async with Sandbox() as sandbox:
        command = ["bash", "-lc", "yes | head -n 1"]
        if sys.argv[1] == "run":
            result = await sandbox.run(command)
        else:
            async with sandbox.start(command) as process:
                result = await process.wait()
        assert result.returncode == 0, result.stderr_text
        assert result.stdout_text == "y\\n", result.stdout_text
        followup = await sandbox.run(["echo", "alive"], check=True)
        assert followup.stdout_text == "alive\\n"

asyncio.run(main())
'''


@pytest.mark.parametrize("mode", ("run", "start"))
def test_early_reader_exit_preserves_the_host_and_sandbox(mode: str) -> None:
    """Keep guest SIGPIPE termination inside the sandbox.

    :param mode: Public process API exercising guest SIGPIPE termination.
    """
    # A broken native unwinder can terminate Python before pytest can report the failure.
    process = subprocess.run(
        [sys.executable, "-c", _SCRIPT, mode],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert process.returncode == 0, (process.returncode, process.stdout, process.stderr)
