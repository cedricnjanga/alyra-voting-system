// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

struct Voter {
  address _address; // used to easily find a voter (see _getVoterIndex)
  bool isRegistered;
  bool hasVoted;
  uint votedProposalId;
}

struct Proposal {
  uint256 id; // used to prevent a users to register multiple proposals
  string description;
  uint voteCount;
}

enum WorkflowStatus {
  RegisteringVoters,
  ProposalsRegistrationStarted,
  ProposalsRegistrationEnded,
  VotingSessionStarted,
  VotingSessionEnded,
  VotesTallied
}

contract Voting is Ownable {
  using Counters for Counters.Counter;

  Voter[] voters;
  Proposal[] proposals;
  Proposal[] winners;

  Counters.Counter private statusCounter;

  event VoterRegistered(address voterAddress); 
  event WorkflowStatusChange(WorkflowStatus previousStatus, WorkflowStatus newStatus);
  event ProposalRegistered(uint proposalId);
  event Voted (address voter, uint proposalId);

  modifier isRegistered() {
    require(_isRegistered(), "You are not a registered voter");
    _;
  }

  modifier isRegisteredOrOwner() {
    require(owner() == msg.sender || _isRegistered(), "You don't have the rights");
    _;
  }

  function getCurrentStatus() public view isRegisteredOrOwner returns(WorkflowStatus status) {
    uint statusInt = statusCounter.current();

    if (statusInt == 0) {
      return WorkflowStatus.RegisteringVoters;
    } else if (statusInt == 1) {
      return WorkflowStatus.ProposalsRegistrationStarted;
    } else if (statusInt == 2) {
      return WorkflowStatus.ProposalsRegistrationEnded;
    } else if (statusInt == 3) {
      return WorkflowStatus.VotingSessionStarted;
    } else if (statusInt == 4) {
      return WorkflowStatus.VotingSessionEnded;
    } else if (statusInt == 5) {
      return WorkflowStatus.VotesTallied;
    }
  }

  // Manipulate state of the voting system
  // Check that conditions are met to go from one status to the next
  // Handle potential equality at the end of the a voting session (by starting a new voting round)
  function goToNextStatus() public onlyOwner {
    require(statusCounter.current() < 5, "Voting session is over");

    WorkflowStatus currenStatus = getCurrentStatus();

    if (currenStatus == WorkflowStatus.RegisteringVoters) {
      require(voters.length >= 2, "You must have at least two voters before moving to next phase");
    } else if (currenStatus == WorkflowStatus.ProposalsRegistrationStarted) {
      require(proposals.length >= 2, "You must have at least two proposals before moving to next phase");
    } else if (currenStatus == WorkflowStatus.VotingSessionStarted) {
      require(_votesCount() > 0, "You must have at least one vote before moving to next phase");
    }

    statusCounter.increment();

    WorkflowStatus newStatus = getCurrentStatus();
    emit WorkflowStatusChange(currenStatus, newStatus);

    _handleNewStatus(newStatus);
  }

  function registrerVoter(address _address) public onlyOwner {
    require(getCurrentStatus() == WorkflowStatus.RegisteringVoters, "Vote regitration is over");
    require(owner() != _address, "An administrator cannot register as a voter");
    require(_getVoterIndex(_address) < 0, "Voter already registered");

    voters.push(Voter(_address, true, false, 0));
    emit VoterRegistered(_address);
  }

  function registrerProposal(string memory description) public isRegisteredOrOwner {
    require(getCurrentStatus() == WorkflowStatus.ProposalsRegistrationStarted, "You can only register a proposal during the proper phase");
    require(!_isEqual(description, ""), "Please enter valid proposal");

    for (uint i = 0; i < proposals.length; i++) {
      require(proposals[i].id != _addressToUint(msg.sender), "You can only register a proposal once");
      require(!_isEqual(description, proposals[i].description), "Proposal already exists");
    }

    uint256 proposalId = _addressToUint(msg.sender);
    proposals.push(Proposal(proposalId, description, 0));

    emit ProposalRegistered(proposalId);
  }

  function vote(uint _proposalId) public isRegistered {
    require(getCurrentStatus() == WorkflowStatus.VotingSessionStarted, "You can only vote during the voting session phase");

    int voterIndex = _getVoterIndex(msg.sender);
    require(!voters[uint(voterIndex)].hasVoted, "You already voted");

    int proposalIndex = _getProposalIndex(_proposalId);

    require(proposalIndex >= 0, "Proposal was not found");

    // Increment proposal vote count  
    proposals[uint(proposalIndex)].voteCount ++;

    // Update voter
    voters[uint(voterIndex)].hasVoted = true;
    voters[uint(voterIndex)].votedProposalId = _proposalId;

    // Emit event
    emit Voted(msg.sender, _proposalId);
  }

  function getProposals() public view isRegisteredOrOwner returns(Proposal[] memory) {
    return proposals;
  }

  function getWinner() public view returns (Proposal memory) {
    require(winners.length != 0, "No winner yet");
    require(winners.length > 0, "Absolute winner net yet determined");
    return winners[0];
  }

  // Utils
  function _isEqual(string memory str1, string memory str2) private pure returns (bool) {
    return keccak256(abi.encodePacked(str1)) == keccak256(abi.encodePacked(str2));
  }

  function _getVoterIndex(address _address) private view returns (int) {
    for (uint i = 0; i < voters.length; i++) {
      if (voters[i]._address == _address) {
        return int(i);
      }
    }

    return -1;
  }

  function _getProposalIndex(uint id) private view returns (int) {
    for (uint i = 0; i < proposals.length; i++) {
      if (proposals[i].id == id) {
        return int(i);
      }
    }

    return -1;
  }

  function _votesCount() private view returns (uint) {
    uint count;

    for (uint i = 0; i < proposals.length; i++) {
      count += proposals[i].voteCount;
    }

    return count;
  }

  function _handleNewStatus(WorkflowStatus currenStatus) private {
    if (currenStatus == WorkflowStatus.VotesTallied) {
      for (uint i = 0; i < proposals.length; i++) {
        if (proposals[i].voteCount == 0) {
          continue;
        }

        if (winners.length > 0) {
          if (proposals[i].voteCount > winners[0].voteCount) {
            delete winners; // We reset the list in order to ensure that will have only one element
          } else if (proposals[i].voteCount < winners[0].voteCount) {
            continue;
          }
        }

        winners.push(proposals[i]);
      }

      if (winners.length > 1) {
        _restartVotingSession();
      }
    }
  }

  // Function called if several proposals get the same amount of at the end of the session.
  // We only keep these proposals and reset data related to previous voting round
  function _restartVotingSession() private {    
    // Remove previous proposals and only keep the ones qualified for the next round
    proposals = winners;
    delete winners;

    // Ensure that vote counts are reset
    for (uint i = 0; i < proposals.length; i ++) {
      proposals[i].voteCount = 0;
    }

    // Reset voters info
    for (uint i = 0; i < voters.length; i++) {
      voters[i].votedProposalId = 0;
      voters[i].hasVoted = false;
    }

    // Go back to previous status to restart voting session
    do {
      statusCounter.decrement();
    } while (getCurrentStatus() != WorkflowStatus.ProposalsRegistrationEnded);

    emit WorkflowStatusChange(WorkflowStatus.VotesTallied, WorkflowStatus.ProposalsRegistrationEnded); 
  }

  function _isRegistered() private view returns (bool) {
    int voterIndex = _getVoterIndex(msg.sender);
    return voterIndex >= 0 && voters[uint(voterIndex)].isRegistered;
  }

  function _addressToUint(address _address) private pure returns (uint256) {
    return uint256(uint160(_address));
  }
}
