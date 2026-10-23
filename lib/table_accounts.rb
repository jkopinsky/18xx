# frozen_string_literal: true

require 'securerandom'

# Accounts for table mode, where nobody needs to log in.
#
# - The Table account: every device that opens the site without logging in is
#   signed in as it automatically, so anyone at the table can watch or play.
# - Seat accounts: one per player name in a table game (or an imported game).
#   Nobody logs in as them; they exist because the engine needs a user for each
#   player. A name that already has an account (someone who signed up) reuses
#   that account.
module TableAccounts
  TABLE_EMAIL = 'table@table.local'
  TABLE_NAME = 'Table'

  module_function

  def table_user
    existing = User[Sequel.function(:lower, :email) => TABLE_EMAIL]
    return existing if existing

    # Someone may already have signed up with the name "Table".
    name = find_by_name(TABLE_NAME) ? "#{TABLE_NAME} (laptop)" : TABLE_NAME
    create(name, TABLE_EMAIL)
  end

  def table_user?(user)
    user&.email == TABLE_EMAIL
  end

  # One account per name, in order. Names are tidied the way the site expects
  # (letters, digits, spaces, - and _), and two names that tidy to the same
  # thing get numbered so each seat has its own account.
  def seat_users(names)
    taken = {}
    names.each_with_index.map do |raw, index|
      name = tidy(raw)
      name = "Player #{index + 1}" if name.empty?
      key = name.downcase
      n = 1
      while taken[key]
        n += 1
        key = "#{name.downcase} #{n}"
      end
      taken[key] = true
      name = "#{name} #{n}" if n > 1
      find_by_name(name) || create(name, email_for(name, index))
    end
  end

  def tidy(name)
    name.to_s.strip.gsub(/[^A-Za-z0-9_ -]/, '').squeeze(' ')[0, 30].to_s.strip
  end

  def find_by_name(name)
    User[Sequel.function(:lower, :name) => name.downcase]
  end

  def email_for(name, index)
    base = name.downcase.gsub(/[^a-z0-9]/, '')
    base = "player#{index + 1}" if base.empty?
    email = "#{base}@table.local"
    n = 1
    while User.by_email(email)
      n += 1
      email = "#{base}#{n}@table.local"
    end
    email
  end

  # Seat accounts get a random password; the Table account too. Table mode
  # never asks for them.
  def create(name, email, password: SecureRandom.hex(12))
    User.create(
      name: name,
      email: email,
      password: password,
      settings: Sequel.pg_jsonb_wrap('consent' => true, 'notifications' => 'none'),
    )
  end
end
