const path = require('path');
const HtmlWebpackPlugin = require('html-webpack-plugin');

module.exports = {
    mode: 'development',
    entry: {
        'main': './src/main.ts'
    },
    devtool: 'inline-source-map',

    module: {
        rules: [
            {
                test: /\.ts$/,
                use: 'ts-loader',
                exclude: /src\/tmp/,
            },
            {
                test: /\.wgsl$/,
                use: 'raw-loader'
            },
            {
                test: /\.(obj|mtl|bin|glb|gltf|fbx|usdc|usdz)$/,
                use: [
                    {
                        loader: 'file-loader',
                        options: {
                            name: '[name].[ext]',
                            outputPath: 'scenes/'
                        }
                    }
                ]
            }
        ]
    },
    resolve: {
        extensions: [
            '.ts', '.js', '.wgsl', '.obj'
        ]
    },
    output: {
        filename: '[name].js',
        path: path.resolve(__dirname, 'dist'),
        clean: true,  // 古いビルド成果物を毎回掃除
    },
    plugins: [
        // index.html をテンプレートにして dist/index.html を自動生成し、
        // <script src="main.js"></script> を自動挿入する
        new HtmlWebpackPlugin({
            template: './index.html',
            inject: 'body',
        }),
    ],
    devServer: {
        // dist/ のみを serve (HtmlWebpackPlugin が dist/index.html を生成するため、
        // 過去のように プロジェクトルートも static dir に並べる必要は無い)
        static: [
            {
                directory: path.join(__dirname, 'dist')
            }
        ],
        compress: true,
        port: 9000
    }
};
