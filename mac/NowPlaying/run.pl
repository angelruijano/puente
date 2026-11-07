# Carga el lector de "Ahora suena" dentro de perl (proceso firmado por Apple)
use DynaLoader;
my $lib = DynaLoader::dl_load_file($ARGV[0]) or die "no se pudo cargar $ARGV[0]";
my $sym = DynaLoader::dl_find_symbol($lib, "puente_nowplaying") or die "símbolo no encontrado";
DynaLoader::dl_install_xsub("main::run", $sym);
run();
