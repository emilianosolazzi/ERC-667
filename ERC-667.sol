// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC1155MetadataURI} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ERC667: A Mixed ERC20/721/1155 Token Standard for Supply Chain Management
/// @notice ERC667 enables assets to transition between unique (ERC721) to fungible (ERC20/1155) states,
///         facilitating supply chain tracking, fractionalization, and lifecycle management.
/// @dev Designed for supply chain processes, with support for multiple asset phases and custom metadata.
/// @author Emiliano Solazzi, 2024
contract ERC667 is Context, Ownable, IERC1155, IERC1155MetadataURI {
    using SafeMath for uint256;
    using Strings for uint256;

    // Metadata
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalMinted;

    // Phase constants
    uint256 private constant PHASE_NFT = 0;

    // Mappings
    mapping(address => uint256[]) private _ownedTokens;
    mapping(uint256 => address) private _phase0Owners;
    mapping(address => mapping(uint256 => uint256[])) private _phasesOwned;
    mapping(uint256 => mapping(uint256 => uint256)) private _totalSupplies;
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) private _balances;
    mapping(uint256 => mapping(uint256 => mapping(address => mapping(address => uint256)))) public phaseAllowances;
    mapping(address => mapping(uint256 => address)) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => uint256[]) public tokenPhaseMultipliers;

    // Events
    event ERC667Transfer(address indexed from, address indexed to, uint256 tokenId, uint256 phase, uint256 amount);
    event TokenPhaseUpdated(uint256 tokenId, uint256 oldPhase, uint256 newPhase);
    event MetadataUpdated(uint256 tokenId, string newUri);

    // Errors
    error NotFound();
    error AlreadyExists();
    error InvalidRecipient();
    error InvalidSender();
    error UnsafeRecipient();
    error Unauthorized();
    error ZeroAddress();
    error NonExistentToken();
    error InvalidPhase();
    error InsufficientBalance(uint256 available, uint256 required);

    // Constructor
    constructor(string memory _name, string memory _symbol, address _owner) Ownable(_owner) {
        name = _name;
        symbol = _symbol;
        decimals = 18; // Standard decimals for ERC20
    }

    // IERC1155 Interface Implementation

    function balanceOf(address account, uint256 id) public view override returns (uint256) {
        require(account != address(0), "ERC667: balance query for the zero address");
        return _balances[id][PHASE_NFT][account];
    }

    function balanceOfBatch(address[] memory accounts, uint256[] memory ids) public view override returns (uint256[] memory) {
        require(accounts.length == ids.length, "ERC667: accounts and ids length mismatch");

        uint256[] memory batchBalances = new uint256[](accounts.length);

        for (uint256 i = 0; i < accounts.length; i++) {
            batchBalances[i] = balanceOf(accounts[i], ids[i]);
        }

        return batchBalances;
    }

    function setApprovalForAll(address operator, bool approved) public override {
        _operatorApprovals[_msgSender()][operator] = approved;
        emit ApprovalForAll(_msgSender(), operator, approved);
    }

    function isApprovedForAll(address account, address operator) public view override returns (bool) {
        return _operatorApprovals[account][operator];
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes memory data) public override {
        require(to != address(0), "ERC667: transfer to the zero address");

        address operator = _msgSender();
        uint256[] memory ids = _asSingletonArray(id);
        uint256[] memory amounts = _asSingletonArray(amount);

        _beforeTokenTransfer(operator, from, to, ids, amounts, data);

        uint256 fromBalance = _balances[id][PHASE_NFT][from];
        require(fromBalance >= amount, "ERC667: insufficient balance for transfer");
        _balances[id][PHASE_NFT][from] = fromBalance - amount;
        _balances[id][PHASE_NFT][to] += amount;

        emit TransferSingle(operator, from, to, id, amount);

        _doSafeTransferAcceptanceCheck(operator, from, to, id, amount, data);
    }

    function safeBatchTransferFrom(address from, address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data) public override {
        require(ids.length == amounts.length, "ERC667: ids and amounts length mismatch");
        require(to != address(0), "ERC667: transfer to the zero address");

        address operator = _msgSender();

        _beforeTokenTransfer(operator, from, to, ids, amounts, data);

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            uint256 amount = amounts[i];

            uint256 fromBalance = _balances[id][PHASE_NFT][from];
            require(fromBalance >= amount, "ERC667: insufficient balance for transfer");
            _balances[id][PHASE_NFT][from] = fromBalance - amount;
            _balances[id][PHASE_NFT][to] += amount;
        }

        emit TransferBatch(operator, from, to, ids, amounts);

        _doSafeBatchTransferAcceptanceCheck(operator, from, to, ids, amounts, data);
    }

    function uri(uint256 tokenId) public view virtual override returns (string memory) {
        return string(abi.encodePacked("https://token-uri/", tokenId.toString()));
    }

    // Implementation of supportsInterface from IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return 
            interfaceId == type(IERC1155).interfaceId ||
            interfaceId == type(IERC1155MetadataURI).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    // Private functions
    function _doSafeTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) private {
        if (_isContract(to)) {
            try IERC1155Receiver(to).onERC1155Received(operator, from, id, amount, data) returns (bytes4 response) {
                if (response != IERC1155Receiver.onERC1155Received.selector) {
                    revert("ERC667: ERC1155Receiver rejected tokens");
                }
            } catch Error(string memory reason) {
                revert(reason);
            } catch {
                revert("ERC667: transfer to non ERC1155Receiver implementer");
            }
        }
    }

    function _doSafeBatchTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) private {
        if (_isContract(to)) {
            try IERC1155Receiver(to).onERC1155BatchReceived(operator, from, ids, amounts, data) returns (bytes4 response) {
                if (response != IERC1155Receiver.onERC1155BatchReceived.selector) {
                    revert("ERC667: ERC1155Receiver rejected tokens");
                }
            } catch Error(string memory reason) {
                revert(reason);
            } catch {
                revert("ERC667: transfer to non ERC1155Receiver implementer");
            }
        }
    }

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual {
        // Hook that can be overridden to add custom functionality
    }

    function _asSingletonArray(uint256 element) private pure returns (uint256[] memory) {
        uint256[] memory array = new uint256[](1);
        array[0] = element;
        return array;
    }

    function _msgSender() internal view override returns (address) {
        return Context._msgSender();
    }

    function _msgData() internal view override returns (bytes calldata) {
        return Context._msgData();
    }

    // Minting function for creating new tokens
    function _mint(address to, uint256 tokenId, uint256 phase, uint256 amount) internal virtual {
        require(to != address(0), "ERC667: mint to the zero address");

        if (phase == PHASE_NFT) {
            require(_phase0Owners[tokenId] == address(0), "ERC667: token already minted");
            _phase0Owners[tokenId] = to;
        }

        _balances[tokenId][phase][to] += amount;
        _totalSupplies[tokenId][phase] += amount;

        emit TransferSingle(_msgSender(), address(0), to, tokenId, amount);

        _doSafeTransferAcceptanceCheck(_msgSender(), address(0), to, tokenId, amount, "");
    }

    // Burning function to destroy tokens
    function _burn(address from, uint256 tokenId, uint256 phase, uint256 amount) internal virtual {
        require(from != address(0), "ERC667: burn from the zero address");

        uint256 balance = _balances[tokenId][phase][from];
        require(balance >= amount, "ERC667: burn amount exceeds balance");

        _balances[tokenId][phase][from] = balance - amount;
        _totalSupplies[tokenId][phase] -= amount;

        if (phase == PHASE_NFT && _balances[tokenId][PHASE_NFT][from] == 0) {
            _phase0Owners[tokenId] = address(0);
        }

        emit TransferSingle(_msgSender(), from, address(0), tokenId, amount);
    }

    // Batch minting function for creating multiple tokens
    function _mintBatch(address to, uint256[] memory tokenIds, uint256[] memory phases, uint256[] memory amounts) internal virtual {
        require(to != address(0), "ERC667: mint to the zero address");
        require(tokenIds.length == phases.length && phases.length == amounts.length, "ERC667: arrays length mismatch");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            _balances[tokenIds[i]][phases[i]][to] += amounts[i];
            _totalSupplies[tokenIds[i]][phases[i]] += amounts[i];
            if (phases[i] == PHASE_NFT) {
                require(_phase0Owners[tokenIds[i]] == address(0), "ERC667: token already minted");
                _phase0Owners[tokenIds[i]] = to;
            }
        }

        emit TransferBatch(_msgSender(), address(0), to, tokenIds, amounts);

        _doSafeBatchTransferAcceptanceCheck(_msgSender(), address(0), to, tokenIds, amounts, "");
    }

    // Batch burning function to destroy multiple tokens
    function _burnBatch(address from, uint256[] memory tokenIds, uint256[] memory phases, uint256[] memory amounts) internal virtual {
        require(from != address(0), "ERC667: burn from the zero address");
        require(tokenIds.length == phases.length && phases.length == amounts.length, "ERC667: arrays length mismatch");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 id = tokenIds[i];
            uint256 phase = phases[i];
            uint256 amount = amounts[i];

            uint256 balance = _balances[id][phase][from];
            require(balance >= amount, "ERC667: burn amount exceeds balance");

            _balances[id][phase][from] = balance - amount;
            _totalSupplies[id][phase] -= amount;

            if (phase == PHASE_NFT && _balances[id][PHASE_NFT][from] == 0) {
                _phase0Owners[id] = address(0);
            }
        }

        emit TransferBatch(_msgSender(), from, address(0), tokenIds, amounts);
    }

    // Function to update the phase of a token
    function _updateTokenPhase(uint256 tokenId, uint256 newPhase) internal virtual {
        require(newPhase != PHASE_NFT, "ERC667: new phase cannot be NFT phase");
        uint256 oldPhase = _getTokenPhase(tokenId);
        require(oldPhase != newPhase, "ERC667: token is already in the requested phase");

        _balances[tokenId][newPhase][_phase0Owners[tokenId]] = _balances[tokenId][oldPhase][_phase0Owners[tokenId]];
        delete _balances[tokenId][oldPhase][_phase0Owners[tokenId]];

        emit TokenPhaseUpdated(tokenId, oldPhase, newPhase);
    }

    // Function to get the current phase of a token
    function _getTokenPhase(uint256 tokenId) internal view returns (uint256) {
        for (uint256 phase = 1; phase < tokenPhaseMultipliers[tokenId].length; phase++) {
            if (_balances[tokenId][phase][_phase0Owners[tokenId]] > 0) {
                return phase;
            }
        }
        return PHASE_NFT;
    }

    // Function to update the metadata URI for a token
    function _updateTokenUri(uint256 tokenId, string memory newUri) internal virtual {
        require(bytes(newUri).length > 0, "ERC667: new URI must be non-empty");
        emit MetadataUpdated(tokenId, newUri);
    }

    // Function to transfer ownership of a token
    function transferTokenOwnership(address from, address to, uint256 tokenId) public virtual {
        require(to != address(0), "ERC667: transfer to the zero address");
        require(from == _phase0Owners[tokenId], "ERC667: only the token owner can transfer ownership");

        _phase0Owners[tokenId] = to;
        _balances[tokenId][PHASE_NFT][from] -= 1;
        _balances[tokenId][PHASE_NFT][to] += 1;

        emit ERC667Transfer(from, to, tokenId, PHASE_NFT, 1);
    }

    // Internal utility to check if an address is a contract
    function _isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    // Receive function to accept Ether
    receive() external payable {}

    // Fallback function to prevent accidental Ether transfers
    fallback() external payable {
        revert("ERC667: contract does not accept Ether");
    }

    // Function to withdraw any Ether sent to the contract
    function withdrawEther(address payable recipient) external onlyOwner {
        require(address(this).balance > 0, "ERC667: no Ether to withdraw");
        recipient.transfer(address(this).balance);
    }

    // Function to retrieve the contract's Ether balance
    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }
}
