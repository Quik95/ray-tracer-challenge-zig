{ pkgs, ... }:

{
  languages.zig = {
    enable = true;
    package = pkgs.zig_0_16;
  };

  # Node is here only so `skills` (skills.sh CLI) works in the shell.
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_24;
  };

  packages = with pkgs; [
    git
    zls          # Zig language server
    actionlint   # static analysis for GitHub Actions workflows
    zizmor       # security/vulnerability audit for GitHub Actions workflows
    pkg-config   # how `zig build` finds libavif
    libavif      # AVIF output (AV1 through libaom)
  ];

  enterShell = ''
    echo "zig $(zig version)" >&2
  '';

  # skills.sh CLI: `skills add <owner>/<repo>@<skill>`, `skills update`.
  # Skills live in .agents/skills (source of truth), symlinked into .claude/skills.
  scripts.skills.exec = ''
    exec npx -y skills "$@"
  '';

  # Static analysis + workflow vulnerability audit. Used locally and in CI.
  scripts.lint.exec = ''
    set -e
    zig fmt --check .
    actionlint
    zizmor --persona=pedantic .github/workflows
  '';

  enterTest = ''
    lint
    zig build --summary all
    zig build test --summary all
  '';

  git-hooks.hooks = {
    actionlint.enable = true;
    zizmor.enable = true;
  };
}
