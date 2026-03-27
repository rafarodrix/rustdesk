import os
import sys

if sys.platform == "win32":
    import codecs
    sys.stdout = codecs.getwriter("utf-8")(sys.stdout.detach())

# ================= CONFIGURACOES TRILINK (2026) =================
NOME_DO_APP = "Trilink Suporte Remoto"
COR_HEX_FLUTTER = "0xFF004696"
SERVIDOR = "acesso.trilinksoftware.com.br"
KEY = "6FpnQH+KbbpX0qw6XxF0xqnIO0QnHImwbvQ5Lv7q6gU="
# ================================================================

def replace_in_file(file_path: str, old_text: str, new_text: str) -> bool:
    if not os.path.exists(file_path):
        print(f"ERRO: arquivo nao encontrado: {file_path}")
        return False

    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Se a alteracao JA ESTIVER no arquivo (ex: commit anterior), consideramos sucesso!
    if new_text in content:
        print(f"OK (Ja Aplicado): {file_path}")
        return True

    if old_text not in content:
        print(f"AVISO: padrao original nao encontrado em {file_path}: {old_text}")
        return False

    new_content = content.replace(old_text, new_text)
    with open(file_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(new_content)

    print(f"Aplicado com sucesso: {file_path}")
    return True

def run_patch() -> None:
    print("--- Iniciando Patch Trilink (Resiliente) ---")
    ok = True

    # 1. Configuracoes de servidor (Rust)
    ok &= replace_in_file("libs/hbb_common/src/config.rs", 'rendezvous_server: "".to_owned()', f'rendezvous_server: "{SERVIDOR}".to_owned()')
    ok &= replace_in_file("libs/hbb_common/src/config.rs", 'key: "".to_owned()', f'key: "{KEY}".to_owned()')

    # 2. Branding (Flutter)
    ok &= replace_in_file("flutter/lib/common.dart", "static const String appName = 'RustDesk';", f"static const String appName = '{NOME_DO_APP}';")

    # 3. Tratamento dinamico para o arquivo de tema (que mudou de lugar)
    theme_path_1 = "flutter/lib/common/theme.dart"
    theme_path_2 = "flutter/lib/theme.dart" # Novo local comum em forks recentes
    
    if os.path.exists(theme_path_1):
        ok &= replace_in_file(theme_path_1, "Colors.teal", f"Color({COR_HEX_FLUTTER})")
    elif os.path.exists(theme_path_2):
        ok &= replace_in_file(theme_path_2, "Colors.teal", f"Color({COR_HEX_FLUTTER})")
    else:
        print("AVISO: Arquivo de cor (theme.dart) nao encontrado nos locais mapeados. Pulando a cor para nao quebrar o build.")
        # Nao definimos ok = False aqui para permitir que o app compile mesmo se nao achar a cor.

    if not ok:
        raise SystemExit("ERRO CRITICO: Patch finalizado com pendencias. O build foi interrompido.")

    print("--- Patch Trilink finalizado com sucesso ---")

if __name__ == "__main__":
    run_patch()