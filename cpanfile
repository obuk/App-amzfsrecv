requires 'perl', '5.010001';
requires 'feature';
requires 'strict';
requires 'warnings';
requires 'Capture::Tiny';
requires 'Cwd';
requires 'File::Temp';
requires 'JSON';
requires 'Moo';
requires 'MooX::Options';
requires 'Perl6::Slurp';

on 'test' => sub {
    requires 'Test::More', '0.98';
};

