
namespace {


} // namespace

int main() {
    auto a = BallDyn(static_cast<int64_t>(240));
    auto b = BallDyn(static_cast<int64_t>(15));
    std::cout << ball_to_string(ball_to_string((a & b))) << std::endl;
    std::cout << ball_to_string(ball_to_string((a | b))) << std::endl;
    std::cout << ball_to_string(ball_to_string((a ^ b))) << std::endl;
    std::cout << ball_to_string(ball_to_string((a >> static_cast<int64_t>(4)))) << std::endl;
    std::cout << ball_to_string(ball_to_string((b << static_cast<int64_t>(4)))) << std::endl;
    std::cout << ball_to_string(ball_to_string((~static_cast<int64_t>(0)))) << std::endl;
    return 0;
}
