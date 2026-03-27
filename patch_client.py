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
STRICT_PATCH = os.getenv("STRICT_PATCH", "0") == "1"

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


def try_replace(candidates, old_text: str, new_text: str, label: str, required: bool) -> bool:
    for file_path in candidates:
        if os.path.exists(file_path):
            if replace_in_file(file_path, old_text, new_text):
                return True
    print(f"AVISO: nao foi possivel aplicar [{label}] em nenhum arquivo candidato.")
    return not required

def run_patch() -> None:
    print("--- Iniciando Patch Trilink (Resiliente 2026) ---")
    ok = True

    # 1) Configuracoes de servidor (compativel com estruturas antigas/novas)
    server_files = [
        "libs/hbb_common/src/config.rs",
        "flutter/lib/common.dart",
    ]
    required_server = STRICT_PATCH
    ok &= try_replace(
        server_files,
        'rendezvous_server: "".to_owned()',
        f'rendezvous_server: "{SERVIDOR}".to_owned()',
        "rust-rendezvous-server",
        required=required_server,
    )
    ok &= try_replace(
        server_files,
        'key: "".to_owned()',
        f'key: "{KEY}".to_owned()',
        "rust-key",
        required=required_server,
    )

    # Fallback no Flutter atual (ServerConfig.fromOptions)
    ok &= try_replace(
        ["flutter/lib/common.dart"],
        'idServer = options[\'custom-rendezvous-server\'] ?? "",',
        f'idServer = options[\'custom-rendezvous-server\'] ?? "{SERVIDOR}",',
        "flutter-default-idServer",
        required=False,
    )
    ok &= try_replace(
        ["flutter/lib/common.dart"],
        'key = options[\'key\'] ?? "";',
        f'key = options[\'key\'] ?? "{KEY}";',
        "flutter-default-key",
        required=False,
    )

    # 2) Branding (best-effort)
    ok &= try_replace(
        ["flutter/lib/common.dart"],
        "static const String appName = 'RustDesk';",
        f"static const String appName = '{NOME_DO_APP}';",
        "app-name-legacy",
        required=False,
    )

    # 3) Cor principal (arquivos antigos e fallback no common.dart atual)
    theme_path_1 = "flutter/lib/common/theme.dart"
    theme_path_2 = "flutter/lib/theme.dart"

    if os.path.exists(theme_path_1):
        ok &= replace_in_file(theme_path_1, "Colors.teal", f"Color({COR_HEX_FLUTTER})")
    elif os.path.exists(theme_path_2):
        ok &= replace_in_file(theme_path_2, "Colors.teal", f"Color({COR_HEX_FLUTTER})")
    else:
        ok &= try_replace(
            ["flutter/lib/common.dart"],
            '"teal": Colors.teal,',
            f'"teal": Color({COR_HEX_FLUTTER}),',
            "common-dart-teal-map",
            required=False,
        )

    if not ok:
        raise SystemExit(
            "ERRO CRITICO: Patch finalizado com pendencias (modo estrito)."
        )

    print("--- Patch Trilink finalizado com sucesso ---")

if __name__ == "__main__":
    run_patch()
