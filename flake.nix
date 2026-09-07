{
  description = "LEX2 reproducible benchmark environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # The pinned nixpkgs revision no longer evaluates x86_64-darwin.
      # Advertise only targets that this lockfile can actually evaluate.
      systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ];
      forEachSystem = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs { inherit system; }));
    in {
      devShells = forEachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig
            pkgs.sqlite
            pkgs.dict
            pkgs.sdcv
            pkgs.hyperfine
            pkgs.zstd
            pkgs.bzip2
            (pkgs.python314.withPackages (ps: [ ps.pyicu ps.slob ]))
          ];
          shellHook = ''
            export LEX2_BENCH_ROOT="$PWD"
            export PATH="$PWD/zig-out/bin:$PATH"
          '';
        };
      });
    };
}
