%% eval_ber_fer.m - BER/FER of the 3 decoder architectures from the RTL simulation files
%
% Reads, for every simulation run in outfeed/sim/<arch>_<test>_<time>/ (the files
% written by 'python script/run.py sim'):
%   stimulus/input.txt              LLR fed to the decoder, 648 samples per line,
%                                   5-bit two's complement, step 0.25 (gen_data.py)
%   stimulus/expected_codeword.txt  clean codeword (reference), 648 bits per line
%   output_codeword.txt             codeword decoded by the RTL, 648 bits per line
% Line f of the three files is the same frame. The SNR of a run is found by
% matching stimulus/input.txt with code/data/<dataset>/input.txt (metadata.json).
% For each architecture and SNR only the newest finished run (status.json written) is used.
%
%   before decoding : hard decision of the input LLR (LLR < 0 -> bit 1)
%   after decoding  : output_codeword.txt
%   BER = wrong bits / compared bits, FER = frames with >= 1 wrong bit / frames
%   BER info = BER over the K = 324 information bits (systematic: first K bits)
%
% Only reads files: no simulation is run and nothing is written.
% Usage: open MATLAB in this folder and run  eval_ber_fer

clear; clc;
root  = fileparts(fileparts(mfilename('fullpath')));      % ldpc_da2_qc_wifi
archs = {'serial', 'partly_parallel', 'fully_parallel'};
% line style / marker size per architecture: identical curves (bit-exact RTL) stay visible on top of each other
style = {'-s', 11; '-o', 9; '--x', 7};
N = 648;  K = 324;

% ---- datasets: code/data/<name>/input.txt + metadata.json ----------------------
mf = dir(fullfile(root, 'code', 'data', '*', 'metadata.json'));
ds = struct('name', {}, 'snr', {}, 'input', {});
for i = 1:numel(mf)
    m = jsondecode(fileread(fullfile(mf(i).folder, mf(i).name)));
    [~, name] = fileparts(mf(i).folder);
    ds(end+1) = struct('name', name, 'snr', m.snr_db, ...
                       'input', fileread(fullfile(mf(i).folder, 'input.txt'))); %#ok<SAGROW>
end

% ---- every architecture: newest run per dataset --------------------------------
res = struct('arch', {}, 'dataset', {}, 'snr', {}, 'frames', {}, 'ber_raw', {}, ...
             'fer_raw', {}, 'ber_dec', {}, 'ber_info', {}, 'fer_dec', {}, ...
             'err_dec', {}, 'result', {}, 'model', {}, 'run', {});
for a = 1:numel(archs)
    runs = dir(fullfile(root, 'outfeed', 'sim', [archs{a} '_*']));
    runs = runs([runs.isdir]);
    [~, order] = sort([runs.datenum], 'descend');          % newest first
    used = {};
    for r = order
        d    = fullfile(runs(r).folder, runs(r).name);
        fin  = fullfile(d, 'stimulus', 'input.txt');
        fref = fullfile(d, 'stimulus', 'expected_codeword.txt');
        fout = fullfile(d, 'output_codeword.txt');
        if ~(isfile(fin) && isfile(fref) && isfile(fout) && isfile(fullfile(d, 'status.json'))), continue; end
        inText = fileread(fin);
        k = find(arrayfun(@(s) strcmp(s.input, inText), ds), 1);
        if isempty(k) || any(strcmp(used, ds(k).name)), continue; end
        used{end+1} = ds(k).name; %#ok<SAGROW>

        dec = bit_rows(fileread(fout), N);
        F   = size(dec, 1);
        ref = bit_rows(fileread(fref), N);   ref = ref(1:F, :);
        raw = llr_rows(inText, N, F) < 0;
        e_raw = raw ~= ref;
        e_dec = dec ~= ref;
        result = '-';  model = '-';
        if isfile(fullfile(d, 'status.json'))
            st = jsondecode(fileread(fullfile(d, 'status.json')));
            result = st.result;
            if isfield(st, 'model_match') && islogical(st.model_match)
                model = mat2str(st.model_match);
            end
        end
        res(end+1) = struct('arch', archs{a}, 'dataset', ds(k).name, 'snr', ds(k).snr, ...
            'frames', F, 'ber_raw', nnz(e_raw) / (F*N), 'fer_raw', mean(any(e_raw, 2)), ...
            'ber_dec', nnz(e_dec) / (F*N), 'ber_info', nnz(e_dec(:, 1:K)) / (F*K), ...
            'fer_dec', mean(any(e_dec, 2)), 'err_dec', nnz(e_dec), ...
            'result', result, 'model', model, 'run', runs(r).name); %#ok<SAGROW>
    end
end
if isempty(res)
    error('No simulation run with output_codeword.txt in outfeed/sim; run python script/run.py sim first.');
end

% ---- table ---------------------------------------------------------------------
fprintf('QC-LDPC (%d,%d) 802.11n - BER/FER from RTL simulation output\n\n', N, K);
fprintf('%-16s %-11s %6s %6s | %10s %8s | %10s %10s %8s %7s | %-6s %-6s %s\n', 'Architecture', ...
        'Dataset', 'SNR', 'Frames', 'BER raw', 'FER raw', 'BER dec', 'BER info', 'FER dec', ...
        'Errors', 'Sim', 'Model', 'Run');
for i = 1:numel(res)
    s = res(i);
    fprintf('%-16s %-11s %6.1f %6d | %10.3e %8.3f | %10.3e %10.3e %8.3f %7d | %-6s %-6s %s\n', ...
            s.arch, s.dataset, s.snr, s.frames, s.ber_raw, s.fer_raw, s.ber_dec, ...
            s.ber_info, s.fer_dec, s.err_dec, s.result, s.model, s.run);
end
fprintf(['\nBER dec = 0 means no wrong bit in the compared bits (frames x %d); ' ...
         'the BER is then below 1/(frames x %d).\n' ...
         'Sim = testbench result (FAIL when errors remain after decoding, expected at low SNR); ' ...
         'Model = RTL output bit-exact with the Python model (true/false, ''-'' = not checked).\n'], N, N);

% ---- BER/FER vs SNR (only when an architecture has runs at >= 2 SNR) -----------
snrs = arrayfun(@(a) numel(unique([res(strcmp({res.arch}, a{1})).snr])), archs);
if any(snrs >= 2)
    figure('Name', 'BER/FER vs SNR');
    tiledlayout(1, 2);
    for p = 1:2
        nexttile; hold on; grid on; set(gca, 'YScale', 'log');
        for a = 1:numel(archs)
            s = res(strcmp({res.arch}, archs{a}));
            if numel(s) < 2, continue; end
            [x, o] = sort([s.snr]);
            if p == 1, y = [s.ber_dec]; else, y = [s.fer_dec]; end
            y = y(o);  y(y == 0) = NaN;                     % 0 cannot be drawn on a log axis
            plot(x, y, style{a, 1}, 'MarkerSize', style{a, 2}, 'DisplayName', strrep(archs{a}, '_', '-'));
        end
        [x, o] = sort([res.snr]);
        if p == 1, y = [res.ber_raw]; else, y = [res.fer_raw]; end
        [x, u] = unique(x(o));  y = y(o);  y = y(u);  y(y == 0) = NaN;
        plot(x, y, 'k--', 'DisplayName', 'before decoding');
        xlabel('SNR (dB)');
        if p == 1, ylabel('BER'); else, ylabel('FER'); end
        legend('Location', 'southwest');
    end
else
    fprintf('Only one SNR per architecture: no BER/FER curve is drawn.\n');
end

% ---- file parsing --------------------------------------------------------------
function B = bit_rows(text, N)
% One codeword per line, '0'/'1' characters -> F x N matrix of 0/1.
L = regexp(strtrim(text), '\s*\n\s*', 'split');
B = char(L) - '0';
assert(size(B, 2) == N && all(B(:) == 0 | B(:) == 1), 'expected %d bits per line', N);
end

function X = llr_rows(text, N, F)
% First F lines of input.txt -> F x N LLR values (5-bit two's complement / 4).
L = regexp(strtrim(text), '\s*\n\s*', 'split');
X = zeros(F, N);
for f = 1:F
    c = L{f}(~isspace(L{f})) - '0';
    assert(numel(c) == 5*N, 'expected %d samples of 5 bits per line', N);
    v = [16 8 4 2 1] * reshape(c, 5, N);
    v(v >= 16) = v(v >= 16) - 32;
    X(f, :) = v / 4;
end
end
