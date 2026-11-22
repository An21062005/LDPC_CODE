% View the input payload, generator matrix, and Simulink encoder output.

projectDir = fileparts(mfilename('fullpath'));
matrixData = load(fullfile(projectDir, 'ldpc_matrices.mat'));

payload_580 = uint8(matrixData.payload_580);
G_1152x580 = uint8(matrixData.G_python);
clean_codeword_1152 = uint8(matrixData.expected_codeword_1152);

load_system(fullfile(projectDir, 'ldpc_encoder_580.slx'));
% Inject three deterministic errors at one-based positions 1, 2, and 3.
noise_mask_1152 = zeros(1152, 1, 'uint8');
noise_mask_1152(1:3) = 1;
modelWorkspace = get_param('ldpc_encoder_580', 'ModelWorkspace');
assignin(modelWorkspace, 'noise_mask_1152', noise_mask_1152);
simulationOutput = sim('ldpc_encoder_580');
noisy_codeword_1152 = uint8(simulationOutput.yout(end, :).');
noise_mask_1152 = bitxor(clean_codeword_1152, noisy_codeword_1152);

assert(numel(payload_580) == 580);
assert(isequal(size(G_1152x580), [1152 580]));
assert(numel(noisy_codeword_1152) == 1152);
assert(nnz(noise_mask_1152) == 3);
assert(isequal(find(noise_mask_1152).', 1:3));

payloadFirst36 = join(string(payload_580(1:36)).', '');
cleanFirst64 = join(string(clean_codeword_1152(1:64)).', '');
noisyFirst64 = join(string(noisy_codeword_1152(1:64)).', '');

fprintf('\nINPUT PAYLOAD: 580 bits\n');
fprintf('First 36 bits: %s = 36''hA5A5A5A5A\n', payloadFirst36);
fprintf('Remaining 544 bits are zero: %d\n', all(payload_580(37:end) == 0));
fprintf('\nGENERATOR MATRIX G: %d x %d\n', size(G_1152x580, 1), size(G_1152x580, 2));
fprintf('\nCLEAN CODEWORD: 1152 bits\n');
fprintf('First 64 bits: %s\n', cleanFirst64);
fprintf('\nNOISY CODEWORD: 1152 bits\n');
fprintf('Flipped bit position: %d\n', find(noise_mask_1152));
fprintf('First 64 bits: %s\n\n', noisyFirst64);

% Export exactly one noisy payload frame as 5-bit LLRs.  Decoder_tb creates
% its two pipeline-flush frames internally; they are not input frames.
noisyInputPath = fullfile(projectDir, 'simulink_noisy_input.txt');
noisyInputFile = fopen(noisyInputPath, 'w');
cleanupNoisyInput = onCleanup(@() fclose(noisyInputFile));
for index = 1:1152
    if noisy_codeword_1152(index) == 0
        fprintf(noisyInputFile, '01111 ');
    else
        fprintf(noisyInputFile, '10001 ');
    end
end
fprintf(noisyInputFile, '\n');
clear cleanupNoisyInput
fprintf('RTL noisy input: %s\n\n', noisyInputPath);

if usejava('desktop')
    % Open all three arrays in MATLAB Variable Editor.
    openvar('payload_580');
    openvar('G_1152x580');
    openvar('clean_codeword_1152');
    openvar('noise_mask_1152');
    openvar('noisy_codeword_1152');

    % Show the structure of G in a separate figure.
    figure('Name', 'Generator matrix G (1152 x 580)');
    spy(G_1152x580);
    title('Generator matrix G: nonzero elements');
    xlabel('Payload bit index (1..580)');
    ylabel('Codeword bit index (1..1152)');
end
