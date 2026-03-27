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

    if old_text not in content:
        print(f"AVISO: padrao nao encontrado em {file_path}: {old_text}")
        return False

    new_content = content.replace(old_text, new_text)
    with open(file_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(new_content)

    print(f"Aplicado: {file_path}")
    return True


def run_patch() -> None:
    print("--- Iniciando Patch Trilink (pipeline 2026) ---")

    ok = True

    # 1. Configuracoes de servidor (Rust)
    ok &= replace_in_file(
        "libs/hbb_common/src/config.rs",
        'rendezvous_server: "".to_owned()',
        f'rendezvous_server: "{SERVIDOR}".to_owned()',
    )
    ok &= replace_in_file(
        "libs/hbb_common/src/config.rs",
        'key: "".to_owned()',
        f'key: "{KEY}".to_owned()',
    )

    # 2. Branding (Flutter)
    ok &= replace_in_file(
        "flutter/lib/common.dart",
        "static const String appName = 'RustDesk';",
        f"static const String appName = '{NOME_DO_APP}';",
    )
    ok &= replace_in_file(
        "flutter/lib/common/theme.dart",
        "Colors.teal",
        f"Color({COR_HEX_FLUTTER})",
    )

    if not ok:
        raise SystemExit("Patch finalizado com pendencias. Revise os avisos acima.")

    print("--- Patch Trilink finalizado com sucesso ---")


if __name__ == "__main__":
    run_patch()
