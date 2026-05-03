{ pkgs, inputs, ... }:

let
  esp-pkgs = inputs.nixpkgs-esp-dev.packages.${pkgs.stdenv.system};
in
{
  env.SDKCONFIG_DEFAULTS = "sdkconfig.defaults.esp_prog2_s3_supermini;sdkconfig.defaults.esp32s3";

  packages = [
    esp-pkgs.esp-idf-full
    pkgs.picocom
    pkgs.usbutils
  ];

  enterShell = ''
    echo "ESP-IDF $(idf.py --version) dev environment ready"
    echo "  idf.py build       - build the project"
    echo "  idf.py flash       - flash to device"
    echo "  picocom /dev/ttyX  - serial monitor"
  '';
}
