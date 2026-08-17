terraform {
  required_version = "~> 1.12"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.68"
    }
  }

  # State maps declared resources to real ones and holds provider credentials in
  # clear text, and this repository is public -- so encryption is not a nicety
  # here, it is what makes the file safe to commit at all.
  #
  # The scheme is in code and the key is not: `state_passphrase` has no default,
  # so it comes from TF_VAR_state_passphrase and OpenTofu refuses to proceed
  # without it. That refusal is the safety property. Without any encryption
  # configuration at all OpenTofu writes plaintext and says nothing about it, so
  # the failure to protect against is a silent one, and a required variable
  # fails loudly instead.
  #
  # `enforced` closes the other half: it stops anyone adding an unencrypted
  # fallback later and quietly downgrading what is already committed.
  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }

    state {
      method   = method.aes_gcm.main
      enforced = true
    }

    plan {
      method   = method.aes_gcm.main
      enforced = true
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}
