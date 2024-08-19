# ERC667: A Mixed ERC20/721/1155 Token Standard for Supply Chain Management

**Author:** Emiliano Solazzi, 2024  
**License:** Apache-2.0

## Overview

ERC667 is a Solidity smart contract that implements a mixed token standard combining ERC20, ERC721, and ERC1155 functionalities.
It is specifically designed for supply chain management, enabling assets to transition between unique (ERC721) and fungible (ERC20/1155) states. 
This allows for comprehensive tracking, fractionalization, and lifecycle management of assets in supply chain processes.

## Features

- **Mixed Token Standard:** Combines ERC20, ERC721, and ERC1155 functionalities into a single contract.
- **Supply Chain Management:** Tracks assets across different phases, including unique and fungible states.
- **Custom Metadata:** Supports custom URIs for tokens, allowing detailed tracking of asset information.
- **Role-Based Access:** Uses OpenZeppelin’s `Ownable` contract to manage administrative roles and permissions.
- **Batch Operations:** Supports batch minting, burning, and transferring of tokens.

Contributing

Contributions are welcome. Please submit issues and pull requests for any enhancements, bug fixes, or new features. Make sure to follow the contribution guidelines.
