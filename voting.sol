//Admin.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/contracts/access/Ownable.sol";

contract Voting is Ownable {

    mapping(address => bool) private whitelist;
    mapping(address => uint) private mappingVotersId;
    mapping(address => bool) private mappingVotersExists;
    mapping(uint => bool) private mappingProposalsExists;
    Voter[] public voters;
    Proposal[] public proposals;
    WorkflowStatus public currentState;
    uint public winningProposalId;
    uint public session;
    uint public countVote;
    uint public countWhiteListed;

    struct Voter {
        string name;
        address addressVoter;
        bool isWhitelisted;
        bool hasVoted;
        uint votedProposalId;
    }

    struct Proposal {
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

    event Whitelisted(address _address);
    event WhitelistRemoved(address _address);
    event VoterRegistered(address voterAddress);
    event WorkflowStatusChange(WorkflowStatus previousStatus, WorkflowStatus newStatus);
    event ProposalRegistered(uint proposalId);
    event Voted (address voter, uint proposalId);

    constructor(){
        currentState = WorkflowStatus.RegisteringVoters;
        session = 1;
    }

    modifier onlyWhitelistedVoter{
        require(whitelist[msg.sender], "You need to be whitelisted to do this action!");
        _;
    }

    modifier sessionOngoing{
        require(currentState != WorkflowStatus.VotesTallied, "Current session is over, please check the winner or start a new session!");
        _;
    }

    function getCountWorkflowStatus() private pure returns (uint){
        return 6;
    }

    function getCountVoters() external view returns (uint){
        return voters.length;
    }

    //REINIT: Permet de commencer une nouvelle session de vote.
    function startNewSession() external onlyOwner {
        //reset all
        uint votersLength = voters.length;
        if (votersLength > 0) {
            for (uint i = 0; i < votersLength; i++) {
                if (whitelist[voters[i].addressVoter]) {
                    delete whitelist[voters[i].addressVoter];
                }
                delete mappingVotersId[voters[i].addressVoter];
                delete mappingVotersExists[voters[i].addressVoter];

            }
        }
        uint proposalsLength = proposals.length;
        if (proposalsLength > 0) {
            for (uint i = 0; i < proposalsLength; i++) {
                delete mappingProposalsExists[i];
            }
        }
        delete voters;
        delete proposals;
        countVote=0;
        countWhiteListed=0;
        currentState = WorkflowStatus.RegisteringVoters;
        session = session + 1;
    }

    function addVoter(string calldata _name, address _address) external onlyOwner{
        require(currentState == WorkflowStatus.RegisteringVoters, "Current State must be RegisteringVoters");
        if (mappingVotersExists[_address]) {
            revert("This voter already exists");
        }
        voters.push(Voter(_name, _address, false, false, 0));
        mappingVotersExists[_address] = true;
        mappingVotersId[_address] = voters.length - 1;
        addVoterToWhiteList(_address);
        emit VoterRegistered(_address);
    }

    //L'administrateur peut récupérer un candidat pour l'ajouter à la whitelist
    function addVoterToWhiteList(address _address) public onlyOwner {
        require(currentState == WorkflowStatus.RegisteringVoters, "Current State must be RegisteringVoters");
        if (!mappingVotersExists[_address]) {
            revert("You need to add the voter with addVoter() first in order to add it to the whitelist");
        }
        require(!whitelist[_address], "This voter is already whitelisted!");
        whitelist[_address] = true;
        voters[mappingVotersId[_address]].isWhitelisted = true;
        countWhiteListed = countWhiteListed + 1;
        emit Whitelisted(_address);
    }

    //Après cela, l'électeur ne pourra plus voter à moins l'ajouter de nouveau à la white list
    function removeVoterFromWhiteList(address _address) external onlyOwner {
        require(currentState == WorkflowStatus.RegisteringVoters, "Current State must be RegisteringVoters");
        if (!mappingVotersExists[_address]) {
            revert("You need to add the voter first with addVoter() in order access to the whitelist");
        }
        require(whitelist[_address], "This voter is not whitelisted!");
        whitelist[_address] = false;
        voters[mappingVotersId[_address]].isWhitelisted = false;
        countWhiteListed = countWhiteListed - 1;
        emit WhitelistRemoved(_address);
    }

    //Ne fonctionne que dans la bonne période et pour les whitelisted
    function addProposal(string calldata _description) external onlyWhitelistedVoter {
        require(currentState == WorkflowStatus.ProposalsRegistrationStarted, "Current State must be ProposalsRegistrationStarted");
        Proposal memory proposal = Proposal(_description, 0);
        proposals.push(proposal);
        mappingProposalsExists[proposals.length - 1]=true;
        emit ProposalRegistered(proposals.length);
    }

    //Tu votes si tu es dans la liste et si c'est le moment
    function vote(uint _proposalId) external onlyWhitelistedVoter {
        require(currentState == WorkflowStatus.VotingSessionStarted, "Current State must be VotingSessionStarted");
        if (!mappingProposalsExists[_proposalId]) {
            revert("Propal do not exist!");
        }
        if(voters[mappingVotersId[msg.sender]].hasVoted){
            revert("You have already voted!");
        }
        proposals[_proposalId].voteCount = proposals[_proposalId].voteCount + 1;
        voters[mappingVotersId[msg.sender]].hasVoted = true;
        voters[mappingVotersId[msg.sender]].votedProposalId = _proposalId;
        countVote = countVote + 1;
        emit Voted(msg.sender, _proposalId);
    }

    //Changer explicitement le statut
    function changeStatus(uint _numStatus) public onlyOwner sessionOngoing {
        if(uint(currentState) == _numStatus){
            revert(string.concat("You requested the same status as the current one"));
        }
        if (uint(_numStatus) > getCountWorkflowStatus() - 1) {
            revert("This status does not exist");
        }
        emit WorkflowStatusChange(currentState, WorkflowStatus(_numStatus));
        currentState = WorkflowStatus(_numStatus);
        //Compter les votes automatiquement à la fin de la session de votes puis bloquer le statut au statut final
        if(currentState == WorkflowStatus.VotingSessionEnded){
            setWinningProposalId();
            changeStatus(uint (WorkflowStatus.VotesTallied));
        }
    }

    //ATTENTION: Arrivé au statut final, j'ai bloqué la possibilité de revenir en arrière, startNewSession() pour recommencer
    //Incrémenter le statut
    function processForward() external onlyOwner sessionOngoing {
        if (uint(currentState) >= getCountWorkflowStatus() - 1) {
            revert("You're already to the last step");
        }
        emit WorkflowStatusChange(currentState, WorkflowStatus(uint(currentState) + 1));
        currentState = WorkflowStatus(uint(currentState) + 1);
        //Compter les votes automatiquement à la fin de la session de votes puis bloquer le statut au statut final
        if(currentState == WorkflowStatus.VotingSessionEnded){
            setWinningProposalId();
            changeStatus(uint (WorkflowStatus.VotesTallied));
        }
    }

    //Décrémenter le statut
    function processBackward() external onlyOwner sessionOngoing{
        if (uint(currentState) <= 0) {
            revert("You're already to the first step");
        }
        emit WorkflowStatusChange(currentState, WorkflowStatus(uint(currentState) - 1));
        currentState = WorkflowStatus(uint(currentState) - 1);
    }



    function setWinningProposalId() private  onlyOwner{
        require(currentState == WorkflowStatus.VotesTallied, "Current State must be VotesTallied, please end session or start a new one");
        if(winningProposalId > 0){
            revert("The winningProposalId has already been set, you can start a new session");
        }
        uint proposalLength = proposals.length;
        if(proposalLength > 0){
            uint highest;
            for(uint i = 0;i < proposalLength;i++){
                if(proposals[i].voteCount > highest) {
                    highest = i;
                }
            }
            winningProposalId=highest;
        }else{
            revert("No proposal was found for this session");
        }
    }
}
