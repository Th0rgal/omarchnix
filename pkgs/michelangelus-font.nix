{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:
stdenvNoCC.mkDerivation {
  pname = "michelangelus-font";
  version = "1.0.0";

  src = fetchurl {
    url = "https://download.microsoft.com/download/e8912dd7-c7e6-4ca1-a36b-c121d3fb238f/Michelangelus%20Fonts.zip";
    hash = "sha256-7vJbfPAMJPY6Wa6hWWcZaOdJCyM8WNwAws3P26BJ3IQ=";
  };

  nativeBuildInputs = [ unzip ];
  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    install -Dm644 Michelangelus-*.ttf -t "$out/share/fonts/truetype/michelangelus"
    if [ -f "Michelangelus Fonts EULA.rtf" ]; then
      install -Dm644 "Michelangelus Fonts EULA.rtf" "$out/share/doc/michelangelus-font/EULA.rtf"
    fi
    runHook postInstall
  '';

  meta = {
    description = "Contemporary Renaissance serif typeface inspired by Michelangelo Buonarroti's handwriting";
    homepage = "https://learn.microsoft.com/en-us/typography/font-list/michelangelus";
    platforms = lib.platforms.all;
  };
}
