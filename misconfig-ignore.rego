# Für das Ignorieren von

package trivy

default ignore = false

# Ignoriert KSV-0109 für die ConfigMap 'opa-config'
# Begründung: Das Secret ist ${CREDENTIAL_TOKEN} und referenziert nur die Umgebungsvariable
# Erstellt: 2026-05-06
ignore {
    input.ID == "KSV-0109"
    contains(input.Message, "'opa-config'")
    contains(input.Message, "'{\"        token\"}'")
}

# Ignoriert KSV-0109 für die ConfigMap 'opa-simulation-config'
# Begründung: Das Secret ist ${CREDENTIAL_TOKEN} und referenziert nur die Umgebungsvariable
# Erstellt: 2026-05-06
ignore {
    input.ID == "KSV-0109"
    contains(input.Message, "'opa-simulation-config'")
    contains(input.Message, "'{\"        token\"}'")
}

