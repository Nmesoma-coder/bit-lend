# BitLend - DeFi Lending Protocol on Stacks

BitLend is a decentralized finance (DeFi) lending protocol built on the Stacks blockchain. It enables users to deposit STX and Bitcoin (via wrapped BTC) to earn interest and allows borrowers to obtain loans by providing collateral.

## Features

- **Deposit & Earn**: Users can deposit STX or xBTC to earn interest
- **Borrow Against Collateral**: Users can borrow assets by providing collateral
- **Collateralization Ratios**: Different tokens have different collateral requirements
- **Dynamic Interest Rates**: Interest rates are configured per token
- **Liquidation Mechanism**: Undercollateralized loans can be liquidated
- **Admin Controls**: Pool parameters can be adjusted by protocol admin

## Smart Contract Structure

The core functionality is implemented in the `lend.clar` contract:

- **Deposit**: Deposit tokens to earn interest
- **Withdraw**: Withdraw deposits plus accrued interest
- **Borrow**: Take a loan by providing collateral
- **Repay Loan**: Repay borrowed amount with interest
- **Liquidate**: Liquidate undercollateralized loans

## Supported Tokens

- **STX**: Native Stacks token
- **xBTC**: Wrapped Bitcoin on Stacks

## Pool Parameters

Each token pool has configurable parameters:

| Parameter | Description |
|-----------|-------------|
| Interest Rate | Annual interest rate (scaled by 100) |
| Collateral Ratio | Required collateral-to-loan ratio (scaled by 100) |
| Liquidation Threshold | Threshold at which loans become liquidatable (scaled by 100) |

## Getting Started

### Prerequisites

- [Clarinet](https://github.com/hirosystems/clarinet) for local development and testing
- Basic knowledge of Clarity language and Stacks blockchain

### Installation

1. Clone the repository
   ```
   git clone https://github.com/your-username/bitlend.git
   cd bitlend
   ```

2. Use Clarinet to test the contract
   ```
   clarinet test
   ```

### Deployment

To deploy to the Stacks blockchain:

1. Ensure you have STX in your wallet
2. Deploy using Clarinet or another Stacks deployment tool
3. Initialize the protocol by calling the `initialize-protocol` function

## Security Considerations

The contract includes several security measures:

- Input validation for all user-provided data
- Authorization checks for admin functions
- Error codes for clear failure reporting
- Proper token transfer validation

## Example Usage

### Depositing Tokens

```clarity
(contract-call? .bitlend deposit "STX" u1000000000)
```

### Taking a Loan

```clarity
(contract-call? .bitlend borrow "STX" u100000000 "xBTC" u5000000 u5256)
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.