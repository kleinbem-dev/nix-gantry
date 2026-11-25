{
  lib,
  stdenvNoCC,
  makeBinaryWrapper,
  bash,
  coreutils,
  jq,
  nix,
  systemd,
  shellcheck,
  versionCheckHook,
  nix-update-script,
  passthruTests ? { },
}:
let
  runtimePath = lib.makeBinPath [
    coreutils
    jq
    nix
    systemd
  ];
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "nix-gantry";
  version = "0.4.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./bin
      ./lib
      ./modules
    ];
  };

  strictDeps = true;
  __structuredAttrs = true;

  nativeBuildInputs = [ makeBinaryWrapper ];
  buildInputs = [ bash ];

  dontConfigure = true;
  dontBuild = true;

  doCheck = true;
  nativeCheckInputs = [ shellcheck ];
  checkPhase = ''
    runHook preCheck
    shellcheck bin/nix-gantry.sh
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 bin/nix-gantry.sh "$out/libexec/nix-gantry"
    substituteInPlace "$out/libexec/nix-gantry" \
      --replace-fail '@version@' "${finalAttrs.version}"

    makeWrapper "$out/libexec/nix-gantry" "$out/bin/nix-gantry" \
      --prefix PATH : "${runtimePath}"
    makeWrapper "$out/libexec/nix-gantry" "$out/bin/publish-manifest" \
      --prefix PATH : "${runtimePath}" \
      --add-flags "publish-manifest"

    mkdir -p "$out/share/nix-gantry"
    cp -r lib modules "$out/share/nix-gantry/"

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  passthru = {
    tests = passthruTests;
    updateScript = nix-update-script { };
  };

  meta = {
    description = "Declarative, manifest-driven atomic updates for NixOS systemd-nspawn containers";
    homepage = "https://github.com/kleinbem-dev/nix-gantry";
    changelog = "https://github.com/kleinbem-dev/nix-gantry/blob/v${finalAttrs.version}/CHANGELOG.md";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ kleinbem ];
    mainProgram = "nix-gantry";
    platforms = lib.platforms.linux;
  };
})
