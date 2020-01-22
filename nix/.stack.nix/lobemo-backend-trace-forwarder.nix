{ system, compiler, flags, pkgs, hsPkgs, pkgconfPkgs, ... }:
  {
    flags = {};
    package = {
      specVersion = "2.0";
      identifier = {
        name = "lobemo-backend-trace-forwarder";
        version = "0.1.0.0";
        };
      license = "Apache-2.0";
      copyright = "2020 IOHK";
      maintainer = "operations@iohk.io";
      author = "Alexander Diemand";
      homepage = "https://github.com/input-output-hk/iohk-monitoring-framework";
      url = "";
      synopsis = "this backend forwards log items to a trace acceptor";
      description = "";
      buildType = "Simple";
      };
    components = {
      "library" = {
        depends = [
          (hsPkgs.base)
          (hsPkgs.iohk-monitoring)
          (hsPkgs.aeson)
          (hsPkgs.async)
          (hsPkgs.bytestring)
          (hsPkgs.network)
          (hsPkgs.safe-exceptions)
          (hsPkgs.stm)
          (hsPkgs.text)
          (hsPkgs.time)
          ];
        };
      };
    } // rec {
    src = (pkgs.lib).mkDefault ../.././plugins/backend-trace-forwarder;
    }