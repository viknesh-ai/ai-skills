function withdraw(account, amount) {
  if (account.balance > amount) {
    account.balance = account.balance - amount;
  }
  return account.balance;
}

module.exports = { withdraw };
