# Safety rules for this PYNQ-Z2 workspace

These rules apply to every agent and every operation in this workspace.

## Protected user data: `Loc`

- Treat any file or directory named `Loc` (case-insensitive) as protected user data, regardless of whether it is on the Windows host, the PYNQ-Z2 microSD card, a mounted removable drive, or the board filesystem.
- Never delete, modify, overwrite, rename, move, copy over, format, or change permissions/ownership of `Loc` or anything inside it.
- Never use `Loc` as a build directory, simulation directory, temporary directory, upload destination, mount target, or programming source.
- Do not run recursive delete, cleanup, synchronization, or formatting commands on any parent directory that may contain `Loc`.
- Before any write to a removable drive, microSD card, or board filesystem, list the exact destination and verify that neither the destination nor any affected path is `Loc` or inside `Loc`.
- If the location or scope of `Loc` is uncertain, stop and ask the user. Do not guess.

## Isolated project area

- Use `pynq_z2_shared_work/` as the only workspace for new project-specific files created for this task.
- Preserve the original Vivado project, original RTL sources, generated artifacts, and all sibling folders unless the user explicitly authorizes a specific change.
- On the PYNQ-Z2 board or microSD card, create and use a new folder named `pynq_z2_shared_work`; it must be a sibling of `Loc`, never a child of `Loc`.
- Do not copy files to the board or microSD card until the exact mounted path has been inspected and confirmed safe.

## Hardware programming safety

- Prefer volatile FPGA configuration through JTAG or a PYNQ overlay.
- Never program QSPI/flash, rewrite the boot image, repartition, format, or re-image the microSD card without a new explicit user request and confirmation of the exact target.
- Before programming the FPGA, verify the target is the PYNQ-Z2 device `xc7z020_1` and state the exact bitstream path.
- Do not program hardware merely as part of probing or detection.

## No destructive cleanup

- Do not delete generated files, temporary folders, logs, or existing project files during this task.
- If cleanup would normally be useful, leave the files in place and report them to the user instead.
