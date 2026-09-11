{ pkgs, ... }:

{
  languages.zig = {
    enable = true;
    package = pkgs.zig_0_16;
  };

  packages = with pkgs; [
    git
    zls          # Zig language server
    actionlint   # static analysis for GitHub Actions workflows
    zizmor       # security/vulnerability audit for GitHub Actions workflows
  ];

  enterShell = ''
    echo "zig $(zig version)" >&2
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
